"""Benchmark report generator.

Public API:
    generate_report(results_dir, out_dir) -> Path

Reads all run_*.jsonl files from results_dir, produces:
- Aggregate CSV + Markdown table: per (workflow, model) → mean score, latency, cost
- Per-workflow ranked leaderboard (Markdown)
- Quality-vs-cost scatter plot for synthesis (PNG via matplotlib, if available)

Output is written to out_dir/report_<timestamp>/ so historical runs are preserved.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import structlog

logger = structlog.get_logger(__name__)

_DEFAULT_RESULTS_DIR = Path(__file__).parent / "results"


def _now_ts() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def _load_results(results_dir: Path) -> list[dict]:
    """Load all run_*.jsonl result rows from a results directory."""
    rows: list[dict] = []
    for path in sorted(results_dir.glob("run_*.jsonl")):
        with path.open() as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def _score_for_row(row: dict) -> float | None:
    """Extract a normalized 0–1 score from a result row."""
    workflow = row.get("workflow")
    if workflow in ("enrichment", "intent_router"):
        correct = row.get("correct")
        if correct is None:
            return None
        return 1.0 if correct else 0.0
    elif workflow == "synthesis":
        grade = row.get("grade", {})
        mean = grade.get("mean_score")
        if mean is None:
            return None
        # Normalize from 1–5 scale to 0–1
        return (mean - 1) / 4.0
    return None


def _aggregate(rows: list[dict]) -> dict[tuple[str, str], dict[str, Any]]:
    """Aggregate rows by (workflow, model) → stats dict."""
    buckets: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in rows:
        if "error" in row:
            continue
        key = (row.get("workflow", "?"), row.get("model", "?"))
        buckets[key].append(row)

    result: dict[tuple[str, str], dict[str, Any]] = {}
    for (workflow, model), bucket_rows in sorted(buckets.items()):
        scores = [s for r in bucket_rows if (s := _score_for_row(r)) is not None]
        latencies = [r["latency_ms"] for r in bucket_rows if "latency_ms" in r]
        costs = [r["cost_usd"] for r in bucket_rows if r.get("cost_usd") is not None]
        n = len(bucket_rows)

        result[(workflow, model)] = {
            "workflow": workflow,
            "model": model,
            "n_cases": n,
            "n_passed": sum(1 for r in bucket_rows if r.get("correct") is True),
            "mean_score": round(statistics.mean(scores), 3) if scores else None,
            "p50_latency_ms": round(statistics.median(latencies), 1) if latencies else None,
            "p95_latency_ms": (
                round(sorted(latencies)[int(len(latencies) * 0.95)], 1) if latencies else None
            ),
            "total_cost_usd": round(sum(costs), 6) if costs else None,
            "cost_per_case_usd": (round(sum(costs) / len(costs), 6) if costs else None),
        }

    return result


def _render_markdown_table(agg: dict[tuple[str, str], dict]) -> str:
    """Render the aggregate as a Markdown table."""
    headers = [
        "Workflow",
        "Model",
        "Cases",
        "Passed",
        "Mean Score",
        "p50 Latency (ms)",
        "p95 Latency (ms)",
        "Total Cost (USD)",
        "Cost/Case (USD)",
    ]
    rows = []
    for stats in agg.values():
        rows.append(
            [
                stats["workflow"],
                stats["model"],
                str(stats["n_cases"]),
                str(stats["n_passed"]),
                str(stats["mean_score"]) if stats["mean_score"] is not None else "—",
                str(stats["p50_latency_ms"]) if stats["p50_latency_ms"] is not None else "—",
                str(stats["p95_latency_ms"]) if stats["p95_latency_ms"] is not None else "—",
                str(stats["total_cost_usd"]) if stats["total_cost_usd"] is not None else "—",
                str(stats["cost_per_case_usd"]) if stats["cost_per_case_usd"] is not None else "—",
            ]
        )

    col_widths = [
        max(len(h), max((len(r[i]) for r in rows), default=0)) for i, h in enumerate(headers)
    ]
    sep = "| " + " | ".join("-" * w for w in col_widths) + " |"

    def fmt_row(r: list[str]) -> str:
        return "| " + " | ".join(v.ljust(col_widths[i]) for i, v in enumerate(r)) + " |"

    lines = [fmt_row(headers), sep] + [fmt_row(r) for r in rows]
    return "\n".join(lines)


def _render_leaderboard(agg: dict[tuple[str, str], dict], workflow: str) -> str:
    """Render a per-workflow ranked leaderboard in Markdown."""
    entries = [s for (wf, _), s in agg.items() if wf == workflow and s["mean_score"] is not None]
    if not entries:
        return f"*No data for {workflow}.*\n"

    ranked = sorted(entries, key=lambda s: (-(s["mean_score"] or 0), s["cost_per_case_usd"] or 0))
    lines = [f"### {workflow.replace('_', ' ').title()} Leaderboard\n"]
    lines.append("| Rank | Model | Mean Score | Cost/Case (USD) | p50 Latency (ms) |")
    lines.append("|------|-------|-----------|----------------|-----------------|")
    for i, s in enumerate(ranked, 1):
        lines.append(
            f"| {i} | {s['model']} | {s['mean_score']} "
            f"| {s['cost_per_case_usd'] or '—'} "
            f"| {s['p50_latency_ms'] or '—'} |"
        )
    return "\n".join(lines) + "\n"


def _try_scatter_plot(agg: dict, out_dir: Path) -> Path | None:
    """Attempt to render a quality-vs-cost scatter for synthesis. Returns path or None."""
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        logger.info("report.scatter.matplotlib_unavailable")
        return None

    entries = [
        s
        for (wf, _), s in agg.items()
        if wf == "synthesis" and s["mean_score"] is not None and s["cost_per_case_usd"] is not None
    ]
    if not entries:
        return None

    charts_dir = out_dir / "charts"
    charts_dir.mkdir(parents=True, exist_ok=True)

    fig, ax = plt.subplots(figsize=(8, 6))
    for s in entries:
        ax.scatter(s["cost_per_case_usd"], s["mean_score"], label=s["model"], s=80)
        ax.annotate(
            s["model"].split("/")[-1],
            (s["cost_per_case_usd"], s["mean_score"]),
            textcoords="offset points",
            xytext=(5, 5),
            fontsize=8,
        )

    ax.set_xlabel("Cost per Case (USD)")
    ax.set_ylabel("Mean Score (0–1)")
    ax.set_title("Synthesis: Quality vs Cost")
    ax.grid(True, alpha=0.3)

    chart_path = charts_dir / "synthesis_quality_vs_cost.png"
    fig.savefig(chart_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    logger.info("report.scatter.written", path=str(chart_path))
    return chart_path


def generate_report(
    results_dir: Path = _DEFAULT_RESULTS_DIR,
    out_dir: Path | None = None,
) -> Path:
    """Generate a benchmark report from all result files in results_dir.

    Args:
        results_dir: Directory containing run_*.jsonl files.
        out_dir: Output directory for the report. Defaults to
                 results_dir/report_<timestamp>/.

    Returns:
        Path to the report directory.
    """
    rows = _load_results(results_dir)
    if not rows:
        raise ValueError(f"No result rows found in {results_dir}")

    logger.info("report.loaded_rows", n=len(rows))

    ts = _now_ts()
    report_dir = out_dir or (results_dir / f"report_{ts}")
    report_dir.mkdir(parents=True, exist_ok=True)

    agg = _aggregate(rows)

    # CSV
    csv_path = report_dir / "aggregate.csv"
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=[
                "workflow",
                "model",
                "n_cases",
                "n_passed",
                "mean_score",
                "p50_latency_ms",
                "p95_latency_ms",
                "total_cost_usd",
                "cost_per_case_usd",
            ],
        )
        writer.writeheader()
        for stats in agg.values():
            writer.writerow(stats)

    # Markdown report
    md_lines: list[str] = [
        "# Grove Benchmark Report",
        f"\nGenerated: {ts}",
        f"\nRows loaded: {len(rows)}",
        "\n## Aggregate Results\n",
        _render_markdown_table(agg),
        "\n## Per-Workflow Leaderboards\n",
    ]
    for workflow in ["enrichment", "intent_router", "synthesis"]:
        md_lines.append(_render_leaderboard(agg, workflow))

    md_lines.append("\n## Notes\n")
    md_lines.append(
        "- **Judge bias**: LLM-as-judge synthesis scoring uses a single Anthropic judge model "
        "(`anthropic/claude-opus-4-7`). Anthropic models may score higher due to in-family bias. "
        "If Anthropic models dominate the synthesis leaderboard, treat results as a yellow flag — "
        "a cross-family second judge is the v2 follow-up.\n"
    )
    md_lines.append(
        "- **Confidence calibration**: enrichment confidence is self-reported by the model and "
        "is not a calibrated probability. Agreement between self-confidence and graded correctness "
        "would be a useful signal but requires more data points than the seed corpus provides.\n"
    )
    md_lines.append(
        "- **Temperature**: all calls use provider defaults (temperature not explicitly set). "
        "For strict reproducibility in future sweeps, consider fixing temperature=0 and seed.\n"
    )

    md_path = report_dir / "report.md"
    md_path.write_text("\n".join(md_lines))

    # Scatter plot (soft dependency on matplotlib)
    _try_scatter_plot(agg, report_dir)

    logger.info("report.written", path=str(report_dir))
    return report_dir


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a Grove benchmark report")
    parser.add_argument(
        "--results",
        default=str(_DEFAULT_RESULTS_DIR),
        help=f"Directory containing run_*.jsonl files (default: {_DEFAULT_RESULTS_DIR})",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output directory for the report (default: <results>/report_<timestamp>/)",
    )
    args = parser.parse_args()
    results_dir = Path(args.results)
    out_dir = Path(args.out) if args.out else None
    report_dir = generate_report(results_dir, out_dir)
    print(f"Report written to: {report_dir}")


if __name__ == "__main__":
    main()
