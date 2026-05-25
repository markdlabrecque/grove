"""LLM-as-judge grader for the RAG synthesis workflow.

Public API:
    grade_synthesis(case, candidate_output, *, api_key, judge_model,
                    cache_db_path) -> SynthesisGradeResult

Scoring axes (1–5 each):
    groundedness — claims supported by retrieved chunks?
    faithfulness — no hallucinated facts beyond the sources?
    relevance    — answers the question asked?
    conciseness  — appropriate length, no padding?

Results are cached in a SQLite database keyed on
(case_id, sha256(candidate_output), judge_model) so re-running the harness
does not re-grade identical outputs.

TDD note: this module is NOT covered by TDD per the ticket — LLM-as-judge
grading is excluded from the programmatic-only TDD gate.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path

import structlog

from grove.llm.openrouter import chat_completion

logger = structlog.get_logger(__name__)

_DEFAULT_JUDGE_MODEL = "anthropic/claude-opus-4-7"
_DEFAULT_CACHE_DB = Path(__file__).parent.parent / "results" / ".judge_cache.db"

_JUDGE_SYSTEM_PROMPT = """\
You are an expert evaluator for a personal-memory assistant's RAG \
(Retrieval-Augmented Generation) answers.

You will receive:
1. A user query
2. Retrieved memory chunks (the context the assistant had access to)
3. A rubric describing what a correct answer must include or exclude
4. The assistant's candidate answer

Score the candidate answer on four axes, each 1–5:
- groundedness (1=ungrounded claims, 5=every claim supported by chunks)
- faithfulness (1=major hallucinations, 5=no fabricated facts)
- relevance (1=off-topic, 5=directly answers the question)
- conciseness (1=bloated/padded, 5=appropriately concise)

Respond with JSON only, exactly this schema:
{
  "groundedness": <int 1-5>,
  "faithfulness": <int 1-5>,
  "relevance": <int 1-5>,
  "conciseness": <int 1-5>,
  "judge_notes": "<one or two sentences explaining the scores>"
}
"""

_JUDGE_USER_TEMPLATE = """\
Query: {query}

Retrieved chunks:
{chunks_block}

Rubric:
{rubric}

Candidate answer:
{candidate_output}
"""


@dataclass(frozen=True)
class SynthesisGradeResult:
    """Result of LLM-as-judge grading for one synthesis case."""

    groundedness: int
    faithfulness: int
    relevance: int
    conciseness: int
    judge_notes: str
    # Mean of the four axes — convenience aggregate.
    mean_score: float
    # True when result was served from the judge cache.
    from_cache: bool


def _candidate_hash(candidate_output: str) -> str:
    return hashlib.sha256(candidate_output.encode()).hexdigest()


def _cache_key(case_id: str, output_hash: str, judge_model: str) -> str:
    return f"{case_id}|{output_hash}|{judge_model}"


def _init_cache(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS judge_cache (
            cache_key TEXT PRIMARY KEY,
            groundedness INTEGER NOT NULL,
            faithfulness INTEGER NOT NULL,
            relevance INTEGER NOT NULL,
            conciseness INTEGER NOT NULL,
            judge_notes TEXT NOT NULL,
            graded_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """
    )
    conn.commit()
    return conn


def _read_cache(conn: sqlite3.Connection, key: str) -> SynthesisGradeResult | None:
    row = conn.execute(
        "SELECT groundedness, faithfulness, relevance, conciseness, judge_notes "
        "FROM judge_cache WHERE cache_key = ?",
        (key,),
    ).fetchone()
    if row is None:
        return None
    g, f, r, c, notes = row
    return SynthesisGradeResult(
        groundedness=g,
        faithfulness=f,
        relevance=r,
        conciseness=c,
        judge_notes=notes,
        mean_score=(g + f + r + c) / 4.0,
        from_cache=True,
    )


def _write_cache(
    conn: sqlite3.Connection,
    key: str,
    result: SynthesisGradeResult,
) -> None:
    conn.execute(
        """
        INSERT OR REPLACE INTO judge_cache
            (cache_key, groundedness, faithfulness, relevance, conciseness, judge_notes)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (
            key,
            result.groundedness,
            result.faithfulness,
            result.relevance,
            result.conciseness,
            result.judge_notes,
        ),
    )
    conn.commit()


def _build_chunks_block(retrieval_results: list[dict]) -> str:
    lines: list[str] = []
    for item in retrieval_results:
        mid = item.get("memory_id", "?")
        content = item.get("chunk_content", "")
        lines.append(f"[#{mid}] {content}")
    return "\n\n".join(lines) if lines else "(no retrieved chunks)"


async def grade_synthesis(
    case: dict,
    candidate_output: str,
    *,
    api_key: str,
    judge_model: str = _DEFAULT_JUDGE_MODEL,
    cache_db_path: Path = _DEFAULT_CACHE_DB,
) -> SynthesisGradeResult:
    """Grade a synthesis output using an LLM judge.

    Args:
        case: Synthesis benchmark case dict (must have query, retrieval_results, rubric).
        candidate_output: The model-generated answer to evaluate.
        api_key: OpenRouter API key for the judge call.
        judge_model: OpenRouter model ID for the judge.
        cache_db_path: Path to the SQLite judge cache database.

    Returns:
        SynthesisGradeResult with four axis scores and judge notes.
    """
    output_hash = _candidate_hash(candidate_output)
    key = _cache_key(case["case_id"], output_hash, judge_model)

    conn = _init_cache(cache_db_path)

    cached = _read_cache(conn, key)
    if cached is not None:
        logger.info("synthesis_judge.cache_hit", case_id=case["case_id"])
        return cached

    chunks_block = _build_chunks_block(case.get("retrieval_results", []))
    user_content = _JUDGE_USER_TEMPLATE.format(
        query=case["query"],
        chunks_block=chunks_block,
        rubric=case.get("rubric", ""),
        candidate_output=candidate_output,
    )

    messages = [
        {"role": "system", "content": _JUDGE_SYSTEM_PROMPT},
        {"role": "user", "content": user_content},
    ]

    log = logger.bind(case_id=case["case_id"], judge_model=judge_model)
    log.info("synthesis_judge.request.start")

    completion = await chat_completion(
        api_key=api_key,
        model=judge_model,
        messages=messages,
        response_format={"type": "json_object"},
        timeout=60.0,
    )

    payload = json.loads(completion.content)
    result = SynthesisGradeResult(
        groundedness=int(payload["groundedness"]),
        faithfulness=int(payload["faithfulness"]),
        relevance=int(payload["relevance"]),
        conciseness=int(payload["conciseness"]),
        judge_notes=str(payload.get("judge_notes", "")),
        mean_score=(
            int(payload["groundedness"])
            + int(payload["faithfulness"])
            + int(payload["relevance"])
            + int(payload["conciseness"])
        )
        / 4.0,
        from_cache=False,
    )

    log.info(
        "synthesis_judge.request.ok",
        mean_score=result.mean_score,
        cost_usd=completion.cost_usd,
    )

    _write_cache(conn, key, result)
    return result
