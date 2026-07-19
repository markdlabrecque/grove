"""Embedding/retrieval quality benchmark — CLI entry point (ticket #520).

Public API:
    cosine_similarity(a, b) -> float
    rank_by_similarity(query_vector, doc_vectors) -> list[str]
    recall_at_k(ranked_ids, relevant_ids, k) -> float
    reciprocal_rank(ranked_ids, relevant_ids) -> float
    evaluate_embedder(provider, corpus, cases, k_values) -> EmbedderEvalResult

This is a sibling to runner.py, not a 4th workflow inside it. The chat
workflows in runner.py all share one shape: send a prompt to OpenRouter,
grade the text response, attribute per-call token cost. Retrieval has none
of that — it embeds a document pool once, embeds each query, ranks by
cosine similarity, and scores rank positions with an IR metric. There is no
LLM call, no judge, and no OpenRouter cost, so it gets its own entry point
and results/summary format instead of being shoehorned into run_workflow().

Usage:
    python -m grove.benchmarks.retrieval \\
        --embedders "bge-m3@http://localhost:11434/v1,text-embedding-3-small@" \\
        [--cases "retr-00*"] \\
        [--k 1,3,5,10] \\
        [--out server/grove/benchmarks/results]

For each embedder spec the runner:
1. Embeds the full retrieval corpus (the searchable memory pool) once.
2. Embeds every case's query.
3. Ranks the pool by cosine similarity to each query.
4. Computes recall@k (for each requested k) and reciprocal rank per case.
5. Writes a JSONL result row per (embedder, case) and a Markdown summary
   table comparing embedders — self-contained, not fed through report.py,
   since IR metrics (recall@k / MRR) don't share the chat workflows' 0-1
   score semantics.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import subprocess
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import structlog

from grove.benchmarks.corpus import load_retrieval_cases, load_retrieval_corpus
from grove.embeddings.openai_provider import OpenAIEmbeddingProvider
from grove.embeddings.provider import EmbeddingProvider

logger = structlog.get_logger(__name__)

_DEFAULT_OUT = Path(__file__).parent / "results"
_DEFAULT_K_VALUES: tuple[int, ...] = (1, 3, 5, 10)
_HARNESS_VERSION = 1


def _git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        return "unknown"


def _now_ts() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


# ---------------------------------------------------------------------------
# Similarity + IR metrics — pure functions, no I/O.
# ---------------------------------------------------------------------------


def _dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b, strict=True))


def _norm(a: list[float]) -> float:
    return math.sqrt(_dot(a, a))


def cosine_similarity(a: list[float], b: list[float]) -> float:
    """Cosine similarity between two equal-length vectors.

    Returns 0.0 if either vector has zero magnitude (undefined cosine,
    treated as "no similarity" rather than raising).
    """
    na, nb = _norm(a), _norm(b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return _dot(a, b) / (na * nb)


def rank_by_similarity(query_vector: list[float], doc_vectors: dict[str, list[float]]) -> list[str]:
    """Rank memory_ids by descending cosine similarity to query_vector.

    Ties are broken by the original dict insertion order (Python sort is
    stable), i.e. corpus order.
    """
    scored = [(mid, cosine_similarity(query_vector, vec)) for mid, vec in doc_vectors.items()]
    scored.sort(key=lambda pair: pair[1], reverse=True)
    return [mid for mid, _ in scored]


def recall_at_k(ranked_ids: list[str], relevant_ids: set[str], k: int) -> float:
    """Fraction of relevant_ids present in the top-k of ranked_ids.

    Returns 0.0 for an empty relevant_ids set (nothing to recall).
    """
    if not relevant_ids:
        return 0.0
    top_k = set(ranked_ids[:k])
    hits = len(top_k & relevant_ids)
    return hits / len(relevant_ids)


def reciprocal_rank(ranked_ids: list[str], relevant_ids: set[str]) -> float:
    """1 / (1-based rank of the first relevant hit); 0.0 if none found."""
    for i, mid in enumerate(ranked_ids, start=1):
        if mid in relevant_ids:
            return 1.0 / i
    return 0.0


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RetrievalCaseResult:
    """Per-case retrieval result for one embedder."""

    case_id: str
    query: str
    ranked_ids: list[str]
    relevant_ids: list[str]
    recall_at_k: dict[int, float]
    reciprocal_rank: float


@dataclass(frozen=True)
class EmbedderEvalResult:
    """Aggregate retrieval result for one embedder across all cases."""

    embedder_name: str
    n_cases: int
    mean_recall_at_k: dict[int, float]
    mean_reciprocal_rank: float
    case_results: list[RetrievalCaseResult]
    embed_latency_ms: float


async def evaluate_embedder(
    provider: EmbeddingProvider,
    corpus: list[dict],
    cases: list[dict],
    k_values: tuple[int, ...] = _DEFAULT_K_VALUES,
) -> EmbedderEvalResult:
    """Evaluate one embedder's retrieval quality against a labelled case set.

    Args:
        provider: Embedding provider to evaluate. Any EmbeddingProvider works —
                  a real OpenAIEmbeddingProvider for a live run, or a fake for
                  deterministic tests. This is the CI-runnability seam: nothing
                  below this call touches settings, env vars, or the network.
        corpus: List of {memory_id, content} dicts — the searchable pool.
        cases: List of {case_id, query, relevant_memory_ids} dicts.
        k_values: recall@k cutoffs to compute.

    Returns:
        EmbedderEvalResult with per-case results and aggregate means.

    Raises:
        ValueError: A case references a relevant_memory_id not present in corpus.
    """
    memory_ids = [doc["memory_id"] for doc in corpus]
    corpus_id_set = set(memory_ids)
    for case in cases:
        missing = set(case["relevant_memory_ids"]) - corpus_id_set
        if missing:
            raise ValueError(
                f"Case {case['case_id']!r} references relevant_memory_ids not in "
                f"corpus: {sorted(missing)}"
            )

    t0 = time.perf_counter()
    doc_vectors_list = await provider.embed_batch([doc["content"] for doc in corpus])
    doc_vecs = dict(zip(memory_ids, doc_vectors_list, strict=True))

    query_vectors = await provider.embed_batch([case["query"] for case in cases])
    embed_latency_ms = (time.perf_counter() - t0) * 1000

    case_results: list[RetrievalCaseResult] = []
    for case, query_vector in zip(cases, query_vectors, strict=True):
        ranked_ids = rank_by_similarity(query_vector, doc_vecs)
        relevant_ids = set(case["relevant_memory_ids"])
        recalls = {k: recall_at_k(ranked_ids, relevant_ids, k) for k in k_values}
        rr = reciprocal_rank(ranked_ids, relevant_ids)
        case_results.append(
            RetrievalCaseResult(
                case_id=case["case_id"],
                query=case["query"],
                ranked_ids=ranked_ids,
                relevant_ids=case["relevant_memory_ids"],
                recall_at_k=recalls,
                reciprocal_rank=rr,
            )
        )

    n = len(case_results)
    mean_recall_at_k = {
        k: (sum(r.recall_at_k[k] for r in case_results) / n if n else 0.0) for k in k_values
    }
    mean_reciprocal_rank = sum(r.reciprocal_rank for r in case_results) / n if n else 0.0

    return EmbedderEvalResult(
        embedder_name=provider.name,
        n_cases=n,
        mean_recall_at_k=mean_recall_at_k,
        mean_reciprocal_rank=mean_reciprocal_rank,
        case_results=case_results,
        embed_latency_ms=round(embed_latency_ms, 1),
    )


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def _result_rows(result: EmbedderEvalResult, git_sha: str, run_ts: str) -> list[dict]:
    """Flatten an EmbedderEvalResult into JSONL-ready row dicts."""
    rows = []
    for cr in result.case_results:
        rows.append(
            {
                "workflow": "retrieval",
                "embedder": result.embedder_name,
                "case_id": cr.case_id,
                "query": cr.query,
                "ranked_ids": cr.ranked_ids,
                "relevant_ids": cr.relevant_ids,
                "recall_at_k": {str(k): v for k, v in cr.recall_at_k.items()},
                "reciprocal_rank": cr.reciprocal_rank,
                "run_ts": run_ts,
                "git_sha": git_sha,
                "harness_version": _HARNESS_VERSION,
            }
        )
    return rows


def _render_summary_markdown(results: list[EmbedderEvalResult], k_values: tuple[int, ...]) -> str:
    """Render a self-contained embedder-comparison summary (recall@k / MRR)."""
    lines = ["# Grove Retrieval Benchmark Summary\n"]
    headers = (
        ["Embedder", "Cases"] + [f"Recall@{k}" for k in k_values] + ["MRR", "Embed Latency (ms)"]
    )
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join("---" for _ in headers) + "|")
    for r in results:
        row = [r.embedder_name, str(r.n_cases)]
        row += [f"{r.mean_recall_at_k[k]:.3f}" for k in k_values]
        row += [f"{r.mean_reciprocal_rank:.3f}", str(r.embed_latency_ms)]
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _parse_embedder_spec(spec: str) -> tuple[str, str | None]:
    """Parse a 'model@base_url' spec.

    base_url is optional; an empty or absent base_url means "use the OpenAI
    SDK default" (api.openai.com), e.g. 'text-embedding-3-small@' or
    'text-embedding-3-small'. A non-empty base_url targets an OpenAI-compatible
    endpoint such as a local Ollama server, e.g. 'bge-m3@http://localhost:11434/v1'.
    """
    if "@" in spec:
        model, _, base_url = spec.partition("@")
        return model.strip(), (base_url.strip() or None)
    return spec.strip(), None


async def _async_main(args: argparse.Namespace) -> None:
    from grove.core.config import settings

    if args.embedders:
        specs = [s.strip() for s in args.embedders.split(",") if s.strip()]
    else:
        # No default pair for embedder comparison (base URLs are environment-
        # specific) — fall back to the currently configured single embedder.
        spec = settings.embedding_model
        if settings.embedding_base_url:
            spec = f"{spec}@{settings.embedding_base_url}"
        specs = [spec]

    corpus = load_retrieval_corpus()
    cases = load_retrieval_cases(case_glob=args.cases)
    if not corpus:
        raise SystemExit("No retrieval corpus cases found under corpus/retrieval_corpus*.jsonl")
    if not cases:
        raise SystemExit("No retrieval cases found under corpus/retrieval_cases*.jsonl")

    k_values = tuple(int(k.strip()) for k in args.k.split(",") if k.strip())

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    git_sha = _git_sha()
    run_ts = _now_ts()

    results: list[EmbedderEvalResult] = []
    all_rows: list[dict] = []
    for spec in specs:
        model, base_url = _parse_embedder_spec(spec)
        logger.info("retrieval.evaluating", embedder=model, base_url=base_url, n_cases=len(cases))
        provider = OpenAIEmbeddingProvider(model=model, base_url=base_url)
        result = await evaluate_embedder(provider, corpus, cases, k_values=k_values)
        results.append(result)
        all_rows.extend(_result_rows(result, git_sha, run_ts))

    out_path = out_dir / f"run_{run_ts}_retrieval.jsonl"
    with out_path.open("w") as fh:
        for row in all_rows:
            fh.write(json.dumps(row) + "\n")

    summary_md = _render_summary_markdown(results, k_values)
    summary_path = out_dir / f"retrieval_summary_{run_ts}.md"
    summary_path.write_text(summary_md)

    logger.info("retrieval.done", out=str(out_path), summary=str(summary_path))
    print(summary_md)


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Grove retrieval benchmark — compare embedders on Grove's own memory "
            "corpus via recall@k and MRR"
        )
    )
    parser.add_argument(
        "--embedders",
        default=None,
        help=(
            "Comma-separated embedder specs as 'model@base_url' (base_url may be "
            "blank for the OpenAI default). Defaults to the single embedder "
            "configured via settings.embedding_model / embedding_base_url. Example: "
            "--embedders 'bge-m3@http://localhost:11434/v1,text-embedding-3-small@'"
        ),
    )
    parser.add_argument(
        "--cases",
        default=None,
        help="Optional fnmatch glob for case_id filtering (e.g. 'retr-00*')",
    )
    default_k_str = ",".join(str(k) for k in _DEFAULT_K_VALUES)
    parser.add_argument(
        "--k",
        default=default_k_str,
        help=f"Comma-separated recall@k cutoffs (default: {default_k_str})",
    )
    parser.add_argument(
        "--out",
        default=str(_DEFAULT_OUT),
        help=f"Output directory for result JSONL + summary (default: {_DEFAULT_OUT})",
    )
    return parser


def main() -> None:
    args = _build_arg_parser().parse_args()
    asyncio.run(_async_main(args))


if __name__ == "__main__":
    main()
