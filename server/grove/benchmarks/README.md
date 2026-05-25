# Grove Benchmark Harness

Automated quality/cost/latency comparison for Grove's three LLM-touching workflows:
**enrichment** (memory classification), **synthesis** (RAG answer composition), and
**intent routing** (query intent classification).

## Quick start

```bash
# Set your OpenRouter API key
export OPENROUTER_API_KEY=sk-or-...

# Run the full sweep with the default model set
make bench

# Generate a report from existing results
make bench-report

# Run only one workflow against a specific model
python -m grove.benchmarks.runner \
    --workflow enrichment \
    --models openai/gpt-4o-mini,anthropic/claude-sonnet-4-6
```

## CLI reference

```
python -m grove.benchmarks.runner --help
python -m grove.benchmarks.report --help
```

Key flags for the runner:
- `--workflow` — `enrichment`, `synthesis`, `intent_router`, or `all`
- `--models` — comma-separated OpenRouter model IDs
- `--cases` — fnmatch glob for case_id filtering (e.g. `enrich-00*`)
- `--out` — output directory for result JSONL files
- `--concurrency` — max concurrent requests per model (default: 4)
- `--judge-model` — LLM judge model for synthesis grading (default: `anthropic/claude-opus-4-7`)
- `--skip-cost-check` — bypass the cost-cap pre-flight (use with caution)

## Cost safety

Before each sweep the runner fetches per-model pricing from the OpenRouter catalog
and estimates the total cost. If `projected_cost + current_month_spend > openrouter_monthly_cap_usd`
(default `$20`) the run aborts with a clear error.

A full sweep across the default model set × 3 workflows × ~75 cases should cost
approximately $1–5 depending on models selected.

## How grading works

| Workflow | Grader | Method |
|----------|--------|--------|
| Enrichment | `grading/enrichment.py` | Programmatic: exact memory_type match + case-insensitive field comparison |
| Intent routing | `grading/intent_router.py` | Programmatic: set-equality on table selection + intent label match |
| Synthesis | `grading/synthesis.py` | LLM-as-judge: 4-axis scoring (groundedness, faithfulness, relevance, conciseness) on a 1–5 scale |

## Judge cache

Synthesis judge results are cached in `results/.judge_cache.db` (SQLite, gitignored) keyed on
`(case_id, sha256(candidate_output), judge_model)`. Re-running the harness with the same
outputs skips re-grading. Delete the cache file to force re-evaluation.

## Interpreting results

- **Mean score**: 0–1 normalized (enrichment/intent = binary 0 or 1; synthesis = (mean_judge_score - 1) / 4)
- **Judge bias**: The synthesis leaderboard uses a single Anthropic judge. Anthropic models may
  score higher due to in-family preference. If Anthropic models dominate, treat results with caution
  and consult the v2 dual-judge follow-up.
- **Current defaults**: `gpt-4o-mini` is included in the default sweep — the report's first read
  should answer "how does the current default compare to alternatives?"

## Adding corpus cases

See `corpus/README.md` for the case schema. Drop new `*_cases*.jsonl` files into
`corpus/` and they are picked up automatically by the loader.

## Output structure

```
results/
  run_20260524T120000Z_enrichment.jsonl  # raw per-(case, model) rows
  run_20260524T120000Z_synthesis.jsonl
  run_20260524T120000Z_intent_router.jsonl
  report_20260524T120500Z/
    report.md         # full markdown report
    aggregate.csv     # machine-readable aggregate stats
    charts/
      synthesis_quality_vs_cost.png
```
