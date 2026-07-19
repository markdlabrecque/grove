# Benchmark Corpus

JSONL files — one per Grove workflow (three chat workflows, plus a corpus +
cases pair for the retrieval benchmark). Each file contains hand-curated
synthetic cases. The loader (`server/grove/benchmarks/corpus.py`) globs the
directory so you can add real (anonymized) cases without code changes: drop
a file like `enrichment_cases_real.jsonl` here.

## enrichment_cases.jsonl

Tests the memory classifier (enrichment pipeline).

| Field | Type | Description |
|-------|------|-------------|
| `case_id` | string | Stable identifier (`enrich-NNN`). |
| `content` | string | Raw memory text fed to the classifier. |
| `expected_memory_type` | string | One of `decisions`, `people_interactions`, `appointments`. |
| `expected_fields` | object | Field→value pairs the extraction should produce. Matched with case-insensitive whitespace-normalized string comparison. |
| `expected_confidence_min` | float | Lower bound (inclusive) for the extraction's `confidence` field. |
| `expected_confidence_max` | float | Upper bound (inclusive) for the extraction's `confidence` field. |

## synthesis_cases.jsonl

Tests RAG answer synthesis (the Ask workflow).

| Field | Type | Description |
|-------|------|-------------|
| `case_id` | string | Stable identifier (`synth-NNN`). |
| `query` | string | User question fed to the synthesizer. |
| `retrieval_results` | array | Pre-staged retrieval: list of `{memory_id, chunk_content, score}` objects. |
| `rubric` | string | Grading criteria for the LLM-as-judge. What a correct answer must include or exclude. |
| `good_answer_notes` | string | Human-readable guidance on what makes a good answer (informational, not graded directly). |

## intent_router_cases.jsonl

Tests query intent classification (the intent router).

| Field | Type | Description |
|-------|------|-------------|
| `case_id` | string | Stable identifier (`intent-NNN`). |
| `query` | string | User question fed to the intent router. |
| `expected_tables` | array | Set of table names the router should select (`decisions`, `people_interactions`, `appointments`, `general`). |
| `expected_intent` | string | Primary intent label (the "best fit" single label). Used for per-case intent accuracy reporting. |

## retrieval_corpus.jsonl

The searchable memory pool for the embedding/retrieval benchmark
(`grove/benchmarks/retrieval.py`). Every candidate memory a query can be
ranked against lives here.

| Field | Type | Description |
|-------|------|-------------|
| `memory_id` | string | Stable identifier (`mem-rNNN`), referenced by `retrieval_cases.jsonl`. |
| `content` | string | Memory text that gets embedded and ranked. |

## retrieval_cases.jsonl

Labelled queries for the embedding/retrieval benchmark: each query paired
with the set of memory ids that count as a correct retrieval.

| Field | Type | Description |
|-------|------|-------------|
| `case_id` | string | Stable identifier (`retr-NNN`). |
| `query` | string | User question the retrieval step should answer. |
| `relevant_memory_ids` | array | `memory_id` values from `retrieval_corpus.jsonl` that are a correct hit for this query. Must all resolve into the corpus — `evaluate_embedder()` raises if any don't. |

**The seed set is illustrative, not a trustworthy verdict.** 8 corpus
entries and 5 cases are only enough to prove the harness plumbing (loader,
ranking, recall@k/MRR math) works end-to-end — they are not a representative
sample of Grove's real memory distribution or query patterns, and a
bge-m3-vs-cloud comparison run against this seed set should not be used to
make a real embedder decision. Meaningful results require a corpus built
from real (anonymized) memories and real query patterns, at a size large
enough for recall@k to be statistically stable — that's follow-up work, not
part of this ticket.

## Adding new cases

Drop a new `*_cases*.jsonl` file in this directory. The loader globs
`enrichment_cases*.jsonl`, `synthesis_cases*.jsonl`, `intent_router_cases*.jsonl`,
and `retrieval_cases*.jsonl` (plus `retrieval_corpus*.jsonl` for the memory
pool) so the new file is picked up automatically. Use the same schema as the
seed files.

Stable `case_id` values are required for reproducible result joins and judge cache keys.
Use the pattern `<prefix>-<NNN>` (e.g. `enrich-real-001` for real anonymized enrichment cases).
