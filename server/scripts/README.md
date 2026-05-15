# server/scripts — review SQL

These scripts are for the weekly and monthly review rituals described in PRD §11.
They run against the live (or dev) Postgres database and print human-readable
sections to the terminal.

## Invocation

Both scripts are designed to be run with `psql -f` inside the `db` container.
Credentials and DB name are taken from `docker-compose.yml`; no extra env vars
are needed beyond a running stack.

### Weekly review (~15 minutes, every Friday)

```bash
docker compose exec -T postgres psql -U oracle -d oracle \
    < server/scripts/weekly_review.sql
```

### Monthly review (~30 minutes, first weekend of the month)

```bash
docker compose exec -T postgres psql -U oracle -d oracle \
    < server/scripts/monthly_review.sql
```

> **Note:** Both commands assume you run them from the repo root, where
> `docker-compose.yml` is located. The script is piped via stdin (`<`) because
> `docker compose exec` resolves `-f` paths relative to the container
> filesystem, not the host. The `-T` flag disables pseudo-TTY allocation so the
> output is clean when piped or captured.

## What each script covers

| Section | weekly | monthly |
|---------|--------|---------|
| Capture counts (7-day / 30-day) | ✓ | ✓ |
| Query counts | ✓ | ✓ (with weekly breakdown) |
| Feedback ratio | ✓ | ✓ |
| Top intents (`tables_searched`) | ✓ | ✓ |
| Refinement-detection rate | ✓ | ✓ |
| Query token totals | ✓ | — |
| Cost-to-date (current calendar month) | ✓ | ✓ (full per-source breakdown) |
| Specialised-table populations | — | ✓ |
| Enrichment lag (median capture → enriched_at) | — | ✓ |
| Enrichment run health | — | ✓ |

## Schema reference

The queries cover these tables (all defined in `server/oracle/models/`):

- `memories` — every captured thought; `created_at`, `enriched`, `enriched_at`, `token_count`
- `query_logs` — every retrieval request; `tables_searched` (JSONB), `synthesis_cost`,
  `intent_router_cost`, `is_refinement`, `user_feedback`
- `enrichment_state` — per-run stats; `notes` JSONB contains `total_cost_usd`,
  `total_input_tokens`, `total_output_tokens` (written by #182)
- `decisions`, `people_interactions`, `tasks`, `appointments` — specialised tables;
  `confidence`, `enrichment_version`, `created_at`
