"""Benchmark runner — CLI entry point.

Usage:
    python -m grove.benchmarks.runner \\
        --workflow {enrichment|synthesis|intent_router|all} \\
        --models openai/gpt-4o-mini,openai/gpt-4o \\
        [--cases "enrich-00*"] \\
        [--out server/grove/benchmarks/results] \\
        [--concurrency 4] \\
        [--judge-model anthropic/claude-opus-4-7] \\
        [--skip-cost-check]

For each (case, model) pair the runner:
1. Sends the prompt to OpenRouter via grove.llm.openrouter.chat_completion
2. Captures raw output, latency, token usage, cost
3. Runs the appropriate grader
4. Writes a JSONL result row to results/run_<timestamp>_<workflow>.jsonl
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path

import structlog

from grove.benchmarks.corpus import (
    load_enrichment_cases,
    load_intent_router_cases,
    load_synthesis_cases,
)
from grove.benchmarks.cost_preflight import CostCapError, run_cost_preflight
from grove.benchmarks.grading.enrichment import grade_enrichment
from grove.benchmarks.grading.intent_router import grade_intent_router
from grove.benchmarks.grading.synthesis import grade_synthesis
from grove.enrichment.schemas import load_classification_prompts
from grove.llm.openrouter import chat_completion
from grove.llm.prompts import load_intent_prompts, load_synthesis_prompts

logger = structlog.get_logger(__name__)

# Default model sweep — covers cheap/mid/frontier across four provider families.
# Override at runtime with --models; override for the Make target with BENCH_MODELS.
DEFAULT_MODELS: list[str] = [
    "openai/gpt-4o-mini",
    "anthropic/claude-haiku-4-5",
    "anthropic/claude-sonnet-4-6",
    "google/gemini-2.5-flash",
    "meta-llama/llama-3.3-70b-instruct",
]

_DEFAULT_CONCURRENCY = 4
_DEFAULT_OUT = Path(__file__).parent / "results"
_DEFAULT_JUDGE_MODEL = "anthropic/claude-opus-4-7"
_HARNESS_VERSION = 1

# Token estimates for cost pre-flight (conservative).
_ENRICHMENT_INPUT_TOKENS = 800
_ENRICHMENT_OUTPUT_TOKENS = 400
_SYNTHESIS_INPUT_TOKENS = 1200
_SYNTHESIS_OUTPUT_TOKENS = 500
_INTENT_INPUT_TOKENS = 300
_INTENT_OUTPUT_TOKENS = 100


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
# Per-workflow runners
# ---------------------------------------------------------------------------


async def _run_enrichment_case(
    case: dict,
    model: str,
    api_key: str,
    semaphore: asyncio.Semaphore,
    git_sha: str,
) -> dict:
    """Run one enrichment case against one model. Returns a result dict."""
    bundle = load_classification_prompts(1)
    messages = [
        {"role": "system", "content": bundle.system_prompt},
        {"role": "user", "content": case["content"]},
    ]

    async with semaphore:
        t0 = time.perf_counter()
        try:
            completion = await chat_completion(
                api_key=api_key,
                model=model,
                messages=messages,
                response_format={"type": "json_object"},
                timeout=60.0,
            )
            latency_ms = (time.perf_counter() - t0) * 1000
        except Exception as exc:
            logger.warning(
                "runner.enrichment.error",
                case_id=case["case_id"],
                model=model,
                error=str(exc),
            )
            return {
                "workflow": "enrichment",
                "case_id": case["case_id"],
                "model": model,
                "error": str(exc),
                "run_ts": _now_ts(),
                "git_sha": git_sha,
            }

    # Parse output
    try:
        output = json.loads(completion.content)
    except json.JSONDecodeError:
        output = {}

    grade = grade_enrichment(case, output)

    return {
        "workflow": "enrichment",
        "case_id": case["case_id"],
        "model": model,
        "raw_output": completion.content,
        "latency_ms": round(latency_ms, 1),
        "prompt_tokens": completion.prompt_tokens,
        "completion_tokens": completion.completion_tokens,
        "total_tokens": completion.total_tokens,
        "cost_usd": completion.cost_usd,
        "correct": grade.correct,
        "field_matches": grade.field_matches,
        "extra_fields": grade.extra_fields,
        "missing_fields": grade.missing_fields,
        "confidence_in_range": grade.confidence_in_range,
        "run_ts": _now_ts(),
        "git_sha": git_sha,
        "harness_version": _HARNESS_VERSION,
    }


async def _run_synthesis_case(
    case: dict,
    model: str,
    api_key: str,
    judge_model: str,
    semaphore: asyncio.Semaphore,
    git_sha: str,
) -> dict:
    """Run one synthesis case against one model. Returns a result dict."""
    bundle = load_synthesis_prompts(1)

    # Build memories block from pre-staged retrieval results.
    memories_lines: list[str] = []
    for src in case.get("retrieval_results", []):
        mid = src["memory_id"]
        excerpt = src["chunk_content"][:500]
        memories_lines.append(f"[#{mid}] {excerpt}")
    memories_block = "\n\n".join(memories_lines)

    user_content = bundle.user_prompt_template.format(
        query=case["query"],
        memories_block=memories_block,
    )
    messages = [
        {"role": "system", "content": bundle.system_prompt},
        {"role": "user", "content": user_content},
    ]

    async with semaphore:
        t0 = time.perf_counter()
        try:
            completion = await chat_completion(
                api_key=api_key,
                model=model,
                messages=messages,
                timeout=60.0,
            )
            latency_ms = (time.perf_counter() - t0) * 1000
        except Exception as exc:
            logger.warning(
                "runner.synthesis.error",
                case_id=case["case_id"],
                model=model,
                error=str(exc),
            )
            return {
                "workflow": "synthesis",
                "case_id": case["case_id"],
                "model": model,
                "error": str(exc),
                "run_ts": _now_ts(),
                "git_sha": git_sha,
            }

    candidate = completion.content

    # Grade with LLM judge (uses cache for repeated runs).
    try:
        grade = await grade_synthesis(
            case,
            candidate,
            api_key=api_key,
            judge_model=judge_model,
        )
        grade_dict = {
            "groundedness": grade.groundedness,
            "faithfulness": grade.faithfulness,
            "relevance": grade.relevance,
            "conciseness": grade.conciseness,
            "mean_score": grade.mean_score,
            "judge_notes": grade.judge_notes,
            "from_cache": grade.from_cache,
        }
    except Exception as exc:
        logger.warning(
            "runner.synthesis.judge_error",
            case_id=case["case_id"],
            error=str(exc),
        )
        grade_dict = {"judge_error": str(exc)}

    return {
        "workflow": "synthesis",
        "case_id": case["case_id"],
        "model": model,
        "raw_output": candidate,
        "latency_ms": round(latency_ms, 1),
        "prompt_tokens": completion.prompt_tokens,
        "completion_tokens": completion.completion_tokens,
        "total_tokens": completion.total_tokens,
        "cost_usd": completion.cost_usd,
        "grade": grade_dict,
        "run_ts": _now_ts(),
        "git_sha": git_sha,
        "harness_version": _HARNESS_VERSION,
    }


async def _run_intent_router_case(
    case: dict,
    model: str,
    api_key: str,
    semaphore: asyncio.Semaphore,
    git_sha: str,
) -> dict:
    """Run one intent-router case against one model. Returns a result dict."""
    bundle = load_intent_prompts(1)
    user_content = bundle.user_prompt_template.format(query=case["query"])
    messages = [
        {"role": "system", "content": bundle.system_prompt},
        {"role": "user", "content": user_content},
    ]

    async with semaphore:
        t0 = time.perf_counter()
        try:
            completion = await chat_completion(
                api_key=api_key,
                model=model,
                messages=messages,
                response_format={"type": "json_object"},
                timeout=30.0,
            )
            latency_ms = (time.perf_counter() - t0) * 1000
        except Exception as exc:
            logger.warning(
                "runner.intent_router.error",
                case_id=case["case_id"],
                model=model,
                error=str(exc),
            )
            return {
                "workflow": "intent_router",
                "case_id": case["case_id"],
                "model": model,
                "error": str(exc),
                "run_ts": _now_ts(),
                "git_sha": git_sha,
            }

    # Parse output
    try:
        output = json.loads(completion.content)
    except json.JSONDecodeError:
        output = {"intents": ["general"]}

    grade = grade_intent_router(case, output)

    return {
        "workflow": "intent_router",
        "case_id": case["case_id"],
        "model": model,
        "raw_output": completion.content,
        "latency_ms": round(latency_ms, 1),
        "prompt_tokens": completion.prompt_tokens,
        "completion_tokens": completion.completion_tokens,
        "total_tokens": completion.total_tokens,
        "cost_usd": completion.cost_usd,
        "correct": grade.correct,
        "tables_correct": grade.tables_correct,
        "intent_correct": grade.intent_correct,
        "predicted_tables": grade.predicted_tables,
        "expected_tables": grade.expected_tables,
        "run_ts": _now_ts(),
        "git_sha": git_sha,
        "harness_version": _HARNESS_VERSION,
    }


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


async def run_workflow(
    workflow: str,
    models: list[str],
    api_key: str,
    out_dir: Path,
    case_glob: str | None = None,
    concurrency: int = _DEFAULT_CONCURRENCY,
    judge_model: str = _DEFAULT_JUDGE_MODEL,
    cap_usd: float = 20.0,
    skip_cost_check: bool = False,
) -> Path:
    """Run one workflow against all models and write results to a JSONL file.

    Returns the path to the written results file.
    """
    # Load cases
    if workflow == "enrichment":
        cases = load_enrichment_cases(case_glob=case_glob)
        input_tok = _ENRICHMENT_INPUT_TOKENS
        output_tok = _ENRICHMENT_OUTPUT_TOKENS
    elif workflow == "synthesis":
        cases = load_synthesis_cases(case_glob=case_glob)
        input_tok = _SYNTHESIS_INPUT_TOKENS
        output_tok = _SYNTHESIS_OUTPUT_TOKENS
    elif workflow == "intent_router":
        cases = load_intent_router_cases(case_glob=case_glob)
        input_tok = _INTENT_INPUT_TOKENS
        output_tok = _INTENT_OUTPUT_TOKENS
    else:
        raise ValueError(f"Unknown workflow: {workflow!r}")

    n_cases = len(cases)
    logger.info("runner.start", workflow=workflow, models=models, n_cases=n_cases)

    if not skip_cost_check:
        try:
            preflight = await run_cost_preflight(
                api_key=api_key,
                models=models,
                n_cases=n_cases,
                cap_usd=cap_usd,
                estimated_input_tokens=input_tok,
                estimated_output_tokens=output_tok,
            )
            logger.info(
                "runner.cost_preflight.ok",
                projected_cost_usd=preflight.projected_cost_usd,
                current_spend_usd=preflight.current_spend_usd,
            )
        except CostCapError as exc:
            logger.error("runner.cost_cap_exceeded", error=str(exc))
            raise

    semaphore = asyncio.Semaphore(concurrency)
    git_sha = _git_sha()

    # Build all tasks
    tasks: list[asyncio.Task] = []
    for model in models:
        for case in cases:
            if workflow == "enrichment":
                coro = _run_enrichment_case(case, model, api_key, semaphore, git_sha)
            elif workflow == "synthesis":
                coro = _run_synthesis_case(case, model, api_key, judge_model, semaphore, git_sha)
            else:
                coro = _run_intent_router_case(case, model, api_key, semaphore, git_sha)
            tasks.append(asyncio.create_task(coro))

    results = await asyncio.gather(*tasks, return_exceptions=False)

    # Write output
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = _now_ts()
    out_path = out_dir / f"run_{ts}_{workflow}.jsonl"
    with out_path.open("w") as fh:
        for row in results:
            fh.write(json.dumps(row) + "\n")

    logger.info("runner.done", workflow=workflow, out=str(out_path), n_results=len(results))
    return out_path


async def _async_main(args: argparse.Namespace) -> None:
    api_key = os.environ.get("OPENROUTER_API_KEY", "")
    if not api_key:
        raise SystemExit("OPENROUTER_API_KEY environment variable is required")

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    out_dir = Path(args.out)

    from grove.core.config import settings

    cap_usd = settings.openrouter_monthly_cap_usd

    workflows = (
        ["enrichment", "synthesis", "intent_router"] if args.workflow == "all" else [args.workflow]
    )

    for workflow in workflows:
        await run_workflow(
            workflow=workflow,
            models=models,
            api_key=api_key,
            out_dir=out_dir,
            case_glob=args.cases,
            concurrency=args.concurrency,
            judge_model=args.judge_model,
            cap_usd=cap_usd,
            skip_cost_check=args.skip_cost_check,
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Grove benchmark runner — compare models across enrichment, "
            "synthesis, and intent routing"
        )
    )
    parser.add_argument(
        "--workflow",
        choices=["enrichment", "synthesis", "intent_router", "all"],
        default="all",
        help="Which workflow to benchmark (default: all)",
    )
    parser.add_argument(
        "--models",
        default=",".join(DEFAULT_MODELS),
        help=(
            "Comma-separated OpenRouter model IDs "
            "(default: the canonical five-model sweep defined in DEFAULT_MODELS)"
        ),
    )
    parser.add_argument(
        "--cases",
        default=None,
        help="Optional fnmatch glob for case_id filtering (e.g. 'enrich-00*')",
    )
    parser.add_argument(
        "--out",
        default=str(_DEFAULT_OUT),
        help=f"Output directory for result JSONL files (default: {_DEFAULT_OUT})",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=_DEFAULT_CONCURRENCY,
        help=f"Max concurrent OpenRouter requests per model (default: {_DEFAULT_CONCURRENCY})",
    )
    parser.add_argument(
        "--judge-model",
        default=_DEFAULT_JUDGE_MODEL,
        help=f"OpenRouter model ID for LLM-as-judge grading (default: {_DEFAULT_JUDGE_MODEL})",
    )
    parser.add_argument(
        "--skip-cost-check",
        action="store_true",
        help="Skip the cost-cap pre-flight check (use with caution)",
    )
    args = parser.parse_args()
    asyncio.run(_async_main(args))


if __name__ == "__main__":
    main()
