# Benchmark Corpus

Three JSONL files — one per Grove workflow. Each file contains hand-curated synthetic cases.
The loader (`server/grove/benchmarks/corpus.py`) globs the directory so you can add real
(anonymized) cases without code changes: drop a file like `enrichment_cases_real.jsonl` here.

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

## Adding new cases

Drop a new `*_cases*.jsonl` file in this directory. The loader globs
`enrichment_cases*.jsonl`, `synthesis_cases*.jsonl`, and `intent_router_cases*.jsonl`
so the new file is picked up automatically. Use the same schema as the seed files.

Stable `case_id` values are required for reproducible result joins and judge cache keys.
Use the pattern `<prefix>-<NNN>` (e.g. `enrich-real-001` for real anonymized enrichment cases).
