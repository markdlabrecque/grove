# Grove Benchmark Report

Generated: 20260525T021248Z

Rows loaded: 77

## Aggregate Results

| Workflow      | Model              | Cases | Passed | Mean Score | p50 Latency (ms) | p95 Latency (ms) | Total Cost (USD) | Cost/Case (USD) |
| ------------- | ------------------ | ----- | ------ | ---------- | ---------------- | ---------------- | ---------------- | --------------- |
| enrichment    | openai/gpt-4o-mini | 32    | 1      | 0.031      | 2766.6           | 4061.8           | 0.002401         | 7.5e-05         |
| intent_router | openai/gpt-4o-mini | 25    | 16     | 0.64       | 834.7            | 1155.5           | 0.001331         | 5.3e-05         |
| synthesis     | openai/gpt-4o-mini | 20    | 0      | 0.95       | 1738.3           | 2757.8           | 0.001635         | 8.2e-05         |

## Per-Workflow Leaderboards

### Enrichment Leaderboard

| Rank | Model | Mean Score | Cost/Case (USD) | p50 Latency (ms) |
|------|-------|-----------|----------------|-----------------|
| 1 | openai/gpt-4o-mini | 0.031 | 7.5e-05 | 2766.6 |

### Intent Router Leaderboard

| Rank | Model | Mean Score | Cost/Case (USD) | p50 Latency (ms) |
|------|-------|-----------|----------------|-----------------|
| 1 | openai/gpt-4o-mini | 0.64 | 5.3e-05 | 834.7 |

### Synthesis Leaderboard

| Rank | Model | Mean Score | Cost/Case (USD) | p50 Latency (ms) |
|------|-------|-----------|----------------|-----------------|
| 1 | openai/gpt-4o-mini | 0.95 | 8.2e-05 | 1738.3 |


## Notes

- **Judge bias**: LLM-as-judge synthesis scoring uses a single Anthropic judge model (`anthropic/claude-opus-4-7`). Anthropic models may score higher due to in-family bias. If Anthropic models dominate the synthesis leaderboard, treat results as a yellow flag — a cross-family second judge is the v2 follow-up.

- **Confidence calibration**: enrichment confidence is self-reported by the model and is not a calibrated probability. Agreement between self-confidence and graded correctness would be a useful signal but requires more data points than the seed corpus provides.

- **Temperature**: all calls use provider defaults (temperature not explicitly set). For strict reproducibility in future sweeps, consider fixing temperature=0 and seed.
