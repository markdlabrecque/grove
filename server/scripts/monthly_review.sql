-- Monthly review — §11 ritual
-- Window: rolling 30 days ending now (UTC), plus specialised-table population
-- counts and enrichment lag analysis.
--
-- Run with (from repo root):
--   docker compose exec -T postgres psql -U grove -d grove \
--       < server/scripts/monthly_review.sql
--
-- Sections
--   1. Capture volume (30-day)
--   2. Query volume (30-day)
--   3. Feedback ratio (30-day)
--   4. Top intents (30-day)
--   5. Refinement-detection rate (30-day)
--   6. Cost breakdown (current calendar month)
--   7. Specialised-table populations
--   8. Enrichment lag (median capture → enriched_at)
--   9. Enrichment run health (last 30 days of enrichment_state rows)

\echo ''
\echo '========================================================'
\echo ' GROVE — MONTHLY REVIEW'
\echo ' Window: rolling 30 days + current-month cost (UTC)'
\echo '========================================================'

-- ---------------------------------------------------------------------------
-- 1. Capture volume (30-day)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 1. Capture volume (past 30 days) ---'

SELECT
    COUNT(*)                                                        AS total_captures,
    COUNT(*) FILTER (WHERE enriched = true)                         AS enriched,
    COUNT(*) FILTER (WHERE enriched = false AND enrichment_error IS NULL)
                                                                    AS pending,
    COUNT(*) FILTER (WHERE enrichment_error IS NOT NULL)            AS errored,
    COUNT(*) FILTER (WHERE source_modality = 'dictated')            AS via_dictation,
    COUNT(*) FILTER (WHERE source_modality = 'typed')               AS via_typing,
    ROUND(AVG(token_count))                                         AS avg_token_count,
    MAX(token_count)                                                AS max_token_count,
    SUM(token_count)                                                AS total_tokens_ingested
FROM memories
WHERE created_at >= NOW() - INTERVAL '30 days';

-- Breakdown by week so capture-habit trend is visible.
\echo ''
\echo '    (weekly breakdown)'

SELECT
    DATE_TRUNC('week', created_at AT TIME ZONE 'UTC')::date         AS week_starting,
    COUNT(*)                                                        AS captures
FROM memories
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 2. Query volume (30-day)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 2. Query volume (past 30 days) ---'

SELECT
    COUNT(*)                                                        AS total_queries,
    COUNT(DISTINCT DATE_TRUNC('day', created_at AT TIME ZONE 'UTC')) AS days_with_queries,
    ROUND(COUNT(*) / NULLIF(
        COUNT(DISTINCT DATE_TRUNC('day', created_at AT TIME ZONE 'UTC')),
        0
    )::numeric, 1)                                                  AS avg_queries_per_active_day,
    COUNT(*) FILTER (WHERE result_count = 0)                        AS zero_result_queries,
    ROUND(AVG(result_count), 1)                                     AS avg_results_per_query
FROM query_logs
WHERE created_at >= NOW() - INTERVAL '30 days';

-- ---------------------------------------------------------------------------
-- 3. Feedback ratio (30-day)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 3. Feedback ratio (past 30 days) ---'

SELECT
    COUNT(*)                                                        AS queries_with_feedback,
    COUNT(*) FILTER (WHERE user_feedback = 'helpful')               AS helpful,
    COUNT(*) FILTER (WHERE user_feedback = 'not_helpful')           AS not_helpful,
    ROUND(
        100.0
        * COUNT(*) FILTER (WHERE user_feedback = 'helpful')
        / NULLIF(COUNT(*) FILTER (WHERE user_feedback IS NOT NULL), 0),
        1
    )                                                               AS helpful_pct
FROM query_logs
WHERE created_at >= NOW() - INTERVAL '30 days'
  AND user_feedback IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. Top intents (30-day)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 4. Top intents from tables_searched (past 30 days, top 10) ---'

SELECT
    key                             AS table_searched,
    COUNT(*)                        AS times_queried,
    COUNT(*) FILTER (WHERE value::text = '"matched"')
                                    AS matched,
    COUNT(*) FILTER (WHERE value::text = '"empty"')
                                    AS empty,
    COUNT(*) FILTER (WHERE value::text = '"skipped"')
                                    AS skipped
FROM query_logs,
     jsonb_each(tables_searched)
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY key
ORDER BY times_queried DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 5. Refinement-detection rate (30-day)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 5. Refinement-detection rate (past 30 days) ---'

SELECT
    COUNT(*)                                                        AS total_queries,
    COUNT(*) FILTER (WHERE is_refinement = true)                    AS refinements,
    ROUND(
        100.0
        * COUNT(*) FILTER (WHERE is_refinement = true)
        / NULLIF(COUNT(*), 0),
        1
    )                                                               AS refinement_pct
FROM query_logs
WHERE created_at >= NOW() - INTERVAL '30 days';

-- ---------------------------------------------------------------------------
-- 6. Cost breakdown (current calendar month)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 6. Cost breakdown (current calendar month, UTC) ---'

WITH month_start AS (
    SELECT DATE_TRUNC('month', NOW() AT TIME ZONE 'UTC') AS t
),
ql_cost AS (
    SELECT
        COALESCE(SUM(synthesis_cost), 0)                            AS synthesis_cost_usd,
        COALESCE(SUM(synthesis_input_tokens), 0)                    AS synthesis_tokens_in,
        COALESCE(SUM(synthesis_output_tokens), 0)                   AS synthesis_tokens_out,
        COALESCE(SUM(intent_router_cost), 0)                        AS router_cost_usd,
        COALESCE(SUM(intent_router_input_tokens), 0)                AS router_tokens_in,
        COALESCE(SUM(intent_router_output_tokens), 0)               AS router_tokens_out
    FROM query_logs, month_start
    WHERE created_at >= month_start.t
),
enr_cost AS (
    SELECT
        COALESCE(SUM((notes->>'total_cost_usd')::float), 0)         AS enrichment_cost_usd,
        COALESCE(SUM((notes->>'total_input_tokens')::int), 0)        AS enrichment_tokens_in,
        COALESCE(SUM((notes->>'total_output_tokens')::int), 0)       AS enrichment_tokens_out
    FROM enrichment_state, month_start
    WHERE run_started_at >= month_start.t
      AND notes IS NOT NULL
)
SELECT
    ROUND(ql_cost.synthesis_cost_usd::numeric, 6)                   AS synthesis_cost_usd,
    ql_cost.synthesis_tokens_in                                      AS synthesis_tokens_in,
    ql_cost.synthesis_tokens_out                                     AS synthesis_tokens_out,
    ROUND(ql_cost.router_cost_usd::numeric, 6)                       AS intent_router_cost_usd,
    ql_cost.router_tokens_in                                         AS router_tokens_in,
    ql_cost.router_tokens_out                                        AS router_tokens_out,
    ROUND(enr_cost.enrichment_cost_usd::numeric, 6)                  AS enrichment_cost_usd,
    enr_cost.enrichment_tokens_in                                    AS enrichment_tokens_in,
    enr_cost.enrichment_tokens_out                                   AS enrichment_tokens_out,
    ROUND(
        (ql_cost.synthesis_cost_usd
         + ql_cost.router_cost_usd
         + enr_cost.enrichment_cost_usd)::numeric,
        6
    )                                                                AS total_cost_usd
FROM ql_cost, enr_cost;

-- ---------------------------------------------------------------------------
-- 7. Specialised-table populations
--    Row counts + average confidence per table, all time and last 30 days.
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 7. Specialised-table populations ---'

SELECT
    'decisions'         AS table_name,
    COUNT(*)            AS total_rows,
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')
                        AS rows_last_30d,
    ROUND(AVG(confidence)::numeric, 3)
                        AS avg_confidence,
    ROUND(AVG(confidence) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')::numeric, 3)
                        AS avg_confidence_last_30d
FROM decisions
UNION ALL
SELECT
    'people_interactions',
    COUNT(*),
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days'),
    ROUND(AVG(confidence)::numeric, 3),
    ROUND(AVG(confidence) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')::numeric, 3)
FROM people_interactions
UNION ALL
SELECT
    'tasks',
    COUNT(*),
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days'),
    ROUND(AVG(confidence)::numeric, 3),
    ROUND(AVG(confidence) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')::numeric, 3)
FROM tasks
UNION ALL
SELECT
    'appointments',
    COUNT(*),
    COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days'),
    ROUND(AVG(confidence)::numeric, 3),
    ROUND(AVG(confidence) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')::numeric, 3)
FROM appointments
ORDER BY table_name;

-- ---------------------------------------------------------------------------
-- 8. Enrichment lag
--    Median and mean time from memory capture (created_at) to enrichment
--    completion (enriched_at). Only considers memories enriched in the past
--    30 days to keep the result relevant to current pipeline performance.
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 8. Enrichment lag (capture → enriched_at, enriched in past 30 days) ---'

SELECT
    COUNT(*)                                                        AS sample_size,
    -- PERCENTILE_CONT requires the argument to be a float8 interval.
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (enriched_at - created_at))
    )                                                               AS median_lag_seconds,
    ROUND(AVG(EXTRACT(EPOCH FROM (enriched_at - created_at)))::numeric, 1)
                                                                    AS mean_lag_seconds,
    ROUND(MIN(EXTRACT(EPOCH FROM (enriched_at - created_at)))::numeric, 1)
                                                                    AS min_lag_seconds,
    ROUND(MAX(EXTRACT(EPOCH FROM (enriched_at - created_at)))::numeric, 1)
                                                                    AS max_lag_seconds
FROM memories
WHERE enriched = true
  AND enriched_at IS NOT NULL
  AND enriched_at >= NOW() - INTERVAL '30 days';

-- ---------------------------------------------------------------------------
-- 9. Enrichment run health (last 30 days of enrichment_state rows)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 9. Enrichment run health (past 30 days) ---'

SELECT
    COUNT(*)                                                        AS total_runs,
    SUM(memories_processed)                                         AS total_memories_processed,
    SUM(classifications_created)                                    AS total_classifications,
    SUM(errors)                                                     AS total_errors,
    COUNT(*) FILTER (WHERE errors > 0)                              AS runs_with_errors,
    ROUND(AVG(
        EXTRACT(EPOCH FROM (run_completed_at - run_started_at))
    )::numeric, 1)                                                  AS avg_run_duration_seconds
FROM enrichment_state
WHERE run_started_at >= NOW() - INTERVAL '30 days';

\echo ''
\echo '    (per-run detail, last 10 runs)'

SELECT
    run_started_at::timestamptz(0)          AS started_at,
    pipeline_version,
    memories_processed,
    classifications_created,
    errors,
    ROUND(EXTRACT(EPOCH FROM (run_completed_at - run_started_at))::numeric, 1)
                                            AS duration_s
FROM enrichment_state
WHERE run_started_at >= NOW() - INTERVAL '30 days'
ORDER BY run_started_at DESC
LIMIT 10;

\echo ''
\echo '========================================================'
\echo ' End of monthly review'
\echo '========================================================'
\echo ''
