# Grove Benchmark Harness

Automated quality/cost/latency comparison for Grove's three LLM-touching workflows:
**enrichment** (memory classification), **synthesis** (RAG answer composition), and
**intent routing** (query intent classification) — plus a separate **retrieval**
benchmark for comparing embedders on recall@k / MRR (see
[Retrieval benchmark](#retrieval-benchmark) below).

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

## Default model sweep

When `--models` is omitted, the runner uses `DEFAULT_MODELS` from
`grove/benchmarks/runner.py` — the canonical five-model sweep:

```
openai/gpt-4o-mini
anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
google/gemini-2.5-flash
meta-llama/llama-3.3-70b-instruct
```

`make bench` passes no `--models` flag unless `BENCH_MODELS` is set, so it
picks up this default automatically. To run a different set ad-hoc:

```bash
make bench BENCH_MODELS=openai/gpt-4o-mini,openai/gpt-4o
# or directly:
python -m grove.benchmarks.runner --workflow all --models openai/gpt-4o-mini
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

## Retrieval benchmark

Separate from the three chat workflows above: `grove/benchmarks/retrieval.py`
compares **embedders** (not chat models) on retrieval quality — embed a query,
rank the memory corpus by cosine similarity, score with recall@k and MRR. It's
a sibling entry point rather than a 4th `runner.py` workflow because it isn't
LLM-shaped: there's no prompt/response to grade or OpenRouter cost to track,
just embed → rank → metric.

```bash
# Compare local bge-m3 (via Ollama) against cloud text-embedding-3-small
export OPENAI_API_KEY=sk-...   # required for the text-embedding-3-small leg
python -m grove.benchmarks.retrieval \
    --embedders "bge-m3@http://localhost:11434/v1,text-embedding-3-small@"

# Or via make (BENCH_EMBEDDERS mirrors BENCH_MODELS for the chat sweep):
make bench-retrieval BENCH_EMBEDDERS="bge-m3@http://localhost:11434/v1,text-embedding-3-small@"
```

Each `model@base_url` spec targets an OpenAI-compatible embeddings endpoint;
an empty base_url (`text-embedding-3-small@` or just `text-embedding-3-small`)
uses the OpenAI SDK default (`api.openai.com`). Omit `--embedders` entirely to
benchmark just the currently configured embedder (`settings.embedding_model` /
`settings.embedding_base_url`).

Corpus format (`corpus/retrieval_corpus.jsonl` + `corpus/retrieval_cases.jsonl`)
is documented in `corpus/README.md` — including a note that the seed set
shipped with the harness is illustrative only, not yet large or representative
enough to make a real embedder decision from.

Output: `results/run_<ts>_retrieval.jsonl` (one row per case per embedder) and
a self-contained `results/retrieval_summary_<ts>.md` comparison table. This
does **not** flow through `report.py` — recall@k/MRR aren't on the same 0–1
scale as the chat workflows' graded scores, so mixing them into one report
would be misleading.

There is no cost pre-flight for retrieval: local bge-m3 via Ollama is free,
and OpenAI's `text-embedding-3-small` pricing is negligible (~$0.00002/1K
tokens) compared to the chat-completion costs the pre-flight guards against.

**CI runs no live embedder.** `evaluate_embedder()` takes an `EmbeddingProvider`
instance, never settings or the factory — tests inject a deterministic fake
provider with pre-registered vectors so recall@k/MRR assertions are exact and
require no network. Only the CLI (`retrieval.py main()`, never exercised by
`make test`) constructs a real `OpenAIEmbeddingProvider` against Ollama or
OpenAI.

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
