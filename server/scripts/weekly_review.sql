-- Weekly review — §11 ritual
-- Window: rolling 7 days ending now (UTC).
--
-- Run with (from repo root):
--   docker compose exec -T postgres psql -U oracle -d oracle \
--       < server/scripts/weekly_review.sql
--
-- Sections
--   1. Capture counts
--   2. Query counts
--   3. Feedback ratio
--   4. Top intents (tables_searched keys)
--   5. Refinement-detection rate
--   6. Average query latency
--   7. Cost-to-date (current calendar month)

\echo ''
\echo '========================================================'
\echo ' THE ORACLE — WEEKLY REVIEW'
\echo ' Window: rolling 7 days (UTC)'
\echo '========================================================'

-- ---------------------------------------------------------------------------
-- 1. Capture counts
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 1. Capture counts (memories created in the past 7 days) ---'

SELECT
    COUNT(*)                                                        AS total_captures,
    COUNT(*) FILTER (WHERE enriched = true)                         AS enriched,
    COUNT(*) FILTER (WHERE enriched = false AND enrichment_error IS NULL)
                                                                    AS pending,
    COUNT(*) FILTER (WHERE enrichment_error IS NOT NULL)            AS errored,
    COUNT(*) FILTER (WHERE source_modality = 'dictated')            AS via_dictation,
    COUNT(*) FILTER (WHERE source_modality = 'typed')               AS via_typing,
    ROUND(AVG(token_count))                                         AS avg_token_count
FROM memories
WHERE created_at >= NOW() - INTERVAL '7 days';

-- ---------------------------------------------------------------------------
-- 2. Query counts
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 2. Query counts (query_logs in the past 7 days) ---'

SELECT
    COUNT(*)                                                        AS total_queries,
    COUNT(DISTINCT DATE_TRUNC('day', created_at AT TIME ZONE 'UTC')) AS days_with_queries,
    ROUND(COUNT(*) / NULLIF(
        COUNT(DISTINCT DATE_TRUNC('day', created_at AT TIME ZONE 'UTC')),
        0
    )::numeric, 1)                                                  AS avg_queries_per_active_day,
    COUNT(*) FILTER (WHERE result_count = 0)                        AS zero_result_queries
FROM query_logs
WHERE created_at >= NOW() - INTERVAL '7 days';

-- ---------------------------------------------------------------------------
-- 3. Feedback ratio
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 3. Feedback ratio (queries with any feedback this week) ---'

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
WHERE created_at >= NOW() - INTERVAL '7 days'
  AND user_feedback IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. Top intents (tables_searched keys — JSONB object)
--    tables_searched shape: {"vector": true, "decisions": "matched"|"empty"|"skipped", ...}
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 4. Top intents from tables_searched (past 7 days, top 10) ---'

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
WHERE created_at >= NOW() - INTERVAL '7 days'
GROUP BY key
ORDER BY times_queried DESC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 5. Refinement-detection rate
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 5. Refinement-detection rate (past 7 days) ---'

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
WHERE created_at >= NOW() - INTERVAL '7 days';

-- ---------------------------------------------------------------------------
-- 6. Average query latency
--    Latency is approximated as the gap between query_log creation time and
--    the feedback_at timestamp when present; for the majority of queries that
--    receive no feedback, we report synthesis token totals as a cost proxy
--    (true latency is not stored in V1 — this is a best-effort indicator).
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 6. Query token totals (synthesis cost proxy; true wall-clock'
\echo '        latency is not stored in V1) ---'

SELECT
    COUNT(*)                                                        AS queries,
    ROUND(AVG(synthesis_input_tokens))                              AS avg_synthesis_input_tokens,
    ROUND(AVG(synthesis_output_tokens))                             AS avg_synthesis_output_tokens,
    ROUND(AVG(intent_router_input_tokens))                          AS avg_router_input_tokens,
    SUM(synthesis_input_tokens + synthesis_output_tokens)           AS total_synthesis_tokens,
    SUM(intent_router_input_tokens + intent_router_output_tokens)   AS total_router_tokens
FROM query_logs
WHERE created_at >= NOW() - INTERVAL '7 days';

-- ---------------------------------------------------------------------------
-- 7. Cost-to-date (current calendar month)
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- 7. Cost-to-date (current calendar month, UTC) ---'

WITH month_start AS (
    SELECT DATE_TRUNC('month', NOW() AT TIME ZONE 'UTC') AS t
),
ql_cost AS (
    SELECT
        COALESCE(SUM(synthesis_cost), 0)       AS synthesis_cost_usd,
        COALESCE(SUM(intent_router_cost), 0)   AS router_cost_usd
    FROM query_logs, month_start
    WHERE created_at >= month_start.t
),
enr_cost AS (
    SELECT
        COALESCE(SUM((notes->>'total_cost_usd')::float), 0) AS enrichment_cost_usd
    FROM enrichment_state, month_start
    WHERE run_started_at >= month_start.t
      AND notes IS NOT NULL
)
SELECT
    ROUND(ql_cost.synthesis_cost_usd::numeric, 6)   AS synthesis_cost_usd,
    ROUND(ql_cost.router_cost_usd::numeric, 6)       AS intent_router_cost_usd,
    ROUND(enr_cost.enrichment_cost_usd::numeric, 6)  AS enrichment_cost_usd,
    ROUND(
        (ql_cost.synthesis_cost_usd
         + ql_cost.router_cost_usd
         + enr_cost.enrichment_cost_usd)::numeric,
        6
    )                                                AS total_cost_usd
FROM ql_cost, enr_cost;

\echo ''
\echo '========================================================'
\echo ' End of weekly review'
\echo '========================================================'
\echo ''
