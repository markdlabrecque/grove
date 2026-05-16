# Grove — V1 Implementation Plan

**Status:** Draft v0.1
**Last updated:** 2026-05-09
**Related:** [grove-prd.md](./grove-prd.md)

This plan breaks the V1 PRD into the five phases sketched in §12 of the PRD, with concrete tasks, deliverables, and exit criteria per phase. Decisions resolved up front from PRD §10:

| Open question | V1 decision |
|---|---|
| Hosting topology (§8.4) | **Hetzner CX22** (Hetzner Cloud, 2 vCPU / 4 GB RAM, single region) |
| Backend stack | **Python 3.12 + FastAPI** (API and enrichment worker share a codebase) |
| Capture entry point | **Action Button → dedicated capture screen** (share sheet deferred) |
| LLM routing | **OpenRouter gateway** for synthesis and classification |
| Embedding provider | **OpenAI `text-embedding-3-small` direct** (1536-dim, cheap, no benefit from routing) |
| Chunking strategy | **Paragraph-based, ~400-token cap, ~50-token overlap** |
| V1 specialized tables | `decisions`, `people_interactions`, `tasks`, `appointments` |
| Specialized-table retrieval | **Hybrid**: vector search on `memories` + intent-driven joins to specialized tables |

---

## Repository layout

A single repo with two top-level apps:

```
the-oracle/
├── server/                   # Python 3.12, FastAPI, SQLAlchemy 2.x, Alembic, uv
│   ├── grove/
│   │   ├── api/              # FastAPI routers: capture, retrieve, feedback, delete
│   │   ├── core/             # config, auth, db, logging
│   │   ├── enrichment/       # pipeline steps, prompts/, classifier, writers
│   │   ├── retrieval/        # query embedding, vector search, intent routing, RAG
│   │   ├── embeddings/       # provider abstraction (OpenAI direct)
│   │   ├── llm/              # OpenRouter client, prompt versioning
│   │   └── models/           # SQLAlchemy models
│   ├── alembic/              # one migration per specialized table
│   ├── prompts/              # versioned classification + synthesis prompts (yaml)
│   ├── tests/
│   └── pyproject.toml
├── ios/                      # SwiftUI app, Xcode project
│   └── Grove/
├── ops/                      # docker-compose.yml, Caddyfile, systemd units, backup scripts
├── docs/
└── .github/workflows/        # CI: ruff, pytest, alembic check
```

Rationale for monorepo: single-user project, server + iOS evolve together, prompts live next to code that uses them.

---

## Phase 1 — Server infrastructure

**Goal:** A reachable, authenticated FastAPI service with Postgres+pgvector, schema migrated, ready to accept captures.

### Tasks

1. **Provision Hetzner CX22** (Ubuntu 24.04 LTS), set up non-root user, SSH on port 22222 per global conventions, UFW, automatic security updates.
2. **Install runtime stack**: Docker + docker-compose for Postgres 16 with `pgvector` extension; Caddy on host for TLS + reverse proxy to the FastAPI container; `uv` for Python deps.
3. **Bootstrap server project**: FastAPI skeleton, Pydantic settings, structlog, healthcheck endpoint, dependency-injected DB session.
4. **Schema migrations (Alembic)** — one migration per logical concern so specialized tables can be dropped/altered individually (per PRD §13.8):
   - `0001_memories.py` — `memories` + indexes (`enriched`, `created_at`, `client_id` UNIQUE)
   - `0002_memory_chunks.py`
   - `0003_query_logs.py`
   - `0004_enrichment_state.py`
   - `0005_decisions.py`
   - `0006_people_interactions.py`
   - `0007_tasks.py` *(see §Schema additions)*
   - `0008_appointments.py` *(see §Schema additions)*
   - HNSW index on `memories.embedding` and `memory_chunks.embedding` (pgvector)
5. **Auth**: bearer-token middleware reading a single token from env/secret; constant-time compare; 401 on miss.
6. **Backups**: `pg_dump` nightly to a Hetzner Storage Box (or Backblaze B2), 30-day retention, restore drill documented.
7. **Deployment**: docker-compose up, Caddy auto-TLS for `grove.<domain>`, systemd unit wrapping `docker compose`, log rotation.
8. **CI**: GitHub Actions running `ruff check`, `ruff format --check`, `pytest`, `alembic upgrade head` against an ephemeral Postgres.

### Schema additions (beyond PRD examples)

Following the same shape as `decisions` and `people_interactions`:

```sql
tasks (
  id UUID PRIMARY KEY,
  memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  due_date DATE,                     -- nullable; LLM extracts when present
  status TEXT,                       -- 'open' (V1 default; lifecycle deferred)
  related_people TEXT[],
  confidence FLOAT NOT NULL,
  enrichment_version INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)

appointments (
  id UUID PRIMARY KEY,
  memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  title TEXT,
  starts_at TIMESTAMPTZ,             -- best-effort LLM extraction
  ends_at TIMESTAMPTZ,
  location TEXT,
  participants TEXT[],
  confidence FLOAT NOT NULL,
  enrichment_version INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
```

Indexes: `(memory_id)` on every specialized table; `(person_name)` on `people_interactions`; `(due_date)` on `tasks`; `(starts_at)` on `appointments`.

### Exit criteria

- `curl -H "Authorization: Bearer …" https://grove.<domain>/healthz` returns 200.
- `alembic upgrade head` runs cleanly on a fresh DB.
- Nightly backup runs and a test restore succeeds in a scratch container.

---

## Phase 2 — Capture path

**Goal:** A capture from the iPhone's Action Button reliably lands in Postgres with embeddings, end-to-end, online and offline.

### Server tasks

1. `POST /v1/captures` accepting `{ client_id, content, source_modality, source_device, language, captured_at }`; UNIQUE on `client_id` makes retries idempotent.
2. **Embedding pipeline** in `grove.embeddings`:
   - If `token_count <= 500`: embed whole content; store on `memories.embedding`.
   - If `> 500`: paragraph-based chunker → ~400-token chunks with ~50-token overlap, sentence-safe within paragraphs; one row per chunk in `memory_chunks`; leave `memories.embedding` NULL.
   - Tokenization via `tiktoken` (cl100k_base). Provider abstraction so re-embedding can target a different model later.
3. Synchronous embed inside the request for V1 simplicity; budget allows it at personal volume. Wrap in a single transaction with the memory insert; on embed failure return 5xx and let the iOS client retry (idempotent via `client_id`).
4. `enriched = false`, `embedding_model = 'text-embedding-3-small'` stamped at insert.
5. Structured logging of capture latency, content length, chunk count.

### iOS tasks

1. **Xcode project**: SwiftUI, iOS 26 deployment target, single target, SwiftData for the local store.
2. **Local model** `LocalMemory { id (clientId UUID), content, capturedAt, sourceModality, language, tokenCountEstimate, syncState }`. Local store is the source of truth (PRD §6.8).
3. **Capture screen**: full-screen multiline `TextEditor`, mic button using `Speech` framework for on-device transcription (live partial results), Save button, haptic confirmation.
4. **Action Button binding**: `CaptureViaDictationIntent` (AppIntent, donated via `OracleShortcutsProvider`) appears in the Shortcuts picker and the Action Button settings panel. User binds it once in Settings → Action Button → Shortcut. (#326)
5. **Dictation capture screen** (`DictationCaptureView` / `DictationCaptureViewModel`): opened by the intent; mic pre-armed; live partial transcript; pulsing-dot recording indicator; explicit Stop button + 3-second trailing-silence auto-stop (`DictationController.silenceTimeout`); editable transcript after stop; Save commits via the existing upload queue. (#326)
6. **Dictation resume banner** (`DictationResumeBanner`): if the user backgrounds the app mid-dictation, the partial transcript is kept in `DictationDraft` (in-memory); on next foreground a banner appears above the tab bar ("Unfinished dictation — N s") with Resume and Dismiss actions. Stacks below the auth-required banner. (#326)
7. **Background sync**: `URLSession` with background configuration. Each pending memory is one upload task; success transitions `pending → synced`; failure with retryable error → backoff; non-retryable (4xx other than 401) → `failed` with error visible in a debug screen.
8. **Sweep on launch + on `NWPathMonitor` path satisfied**: re-enqueue all `pending`/`failed` items.
9. **Keychain** stores the bearer token + server URL; settings screen lets you paste them on first run.

### Exit criteria

- 50 captures in a row from cold launch, half offline, all reach the server with no duplicates.
- Capture-to-local-confirm under 500 ms on iPhone 17 (PRD §7.1).
- Embedding + insert under ~1.5 s server-side for a 200-word capture; under 5 s for a 2 000-word capture.

---

## Phase 3 — Retrieval path

**Goal:** Conversational retrieval working end-to-end with hybrid search and full query logging.

### Server tasks

1. `POST /v1/queries` accepting `{ query_text }`. Returns `{ answer, sources: [{memory_id, excerpt, score}], query_id }`.
2. **Query log entry** created up front with `query_text` + `query_embedding`; updated at end with results, model, token counts.
3. **Embedding** the query via OpenAI `text-embedding-3-small`.
4. **Vector search**:
   - Top-K (default 12) cosine search over `memory_chunks.embedding` UNION `memories.embedding` (where chunks NULL), de-duplicated by `memory_id`, keeping best score per memory.
5. **Intent router** (hybrid retrieval, kept deliberately small for V1):
   - A tiny LLM call (cheap model via OpenRouter) classifies the query into zero or more of: `decisions`, `people_interactions`, `tasks`, `appointments`, or `general`.
   - For each detected intent, run a structured query against the matching specialized table (e.g., `WHERE person_name ILIKE …` for people-flavored queries; `WHERE starts_at >= now()` for "what's coming up"). Specialized matches contribute their parent `memory_id` to the candidate set with a small score boost.
   - `tables_searched` on the query log records exactly which tables participated — this is the signal needed to evaluate whether hybrid is earning its weight (PRD §11).
6. **RAG synthesis**: compose query + retrieved memory excerpts (full text for short memories, matched chunk(s) + neighbours for long ones) into a system+user prompt; call OpenRouter; require inline `[#memory_id]`-style references the iOS UI can hyperlink. Default model is configurable; ship pointing at a cheap Haiku-class or GPT-4o-mini-class model.
7. `POST /v1/queries/{id}/feedback` updates `user_feedback` + `feedback_at`.
8. **Refinement detection**: heuristic — if a new query within 5 minutes has cosine similarity ≥ 0.85 to the previous query embedding, set `is_refinement = true` and link `parent_query_id`. Tunable from a single config block.
9. `DELETE /v1/memories/{id}` — cascades to chunks/specialized rows; query logs keep the row but their FK references resolve to NULL by design (PRD §6.6).

### iOS tasks

1. **Retrieval screen** (chat-style, single-turn for V1): input field, streaming or non-streaming answer view, source cards beneath the answer.
2. **Source detail view**: full memory content, capture metadata, **Delete** button with confirm.
3. **Feedback chips** (👍 / 👎) below each answer, fire-and-forget.
4. Tab bar with two tabs: Capture, Ask. (Action Button still routes to Capture.)

### Exit criteria

- 5 s end-to-end query latency on a corpus of 500+ memories.
- Synthesized answer contains at least one valid source reference; tapping it opens the source memory.
- `query_logs` row written with `tables_searched`, `returned_memory_ids`, token counts populated for every query.

---

## Phase 4 — Enrichment

**Goal:** Hourly batch enrichment classifying memories into the four specialized tables, versioned and resumable.

### Tasks

1. **Worker entrypoint** `python -m grove.enrichment.run` invoked by cron on the Hetzner box (`0 * * * *`); logs to journald; emits an `enrichment_state` row per run.
2. **Pipeline steps** (PRD §13.2), each a pure function that's independently testable:
   1. Fetch a batch of `memories WHERE enriched = false ORDER BY created_at LIMIT N` (default 50). Lock with `FOR UPDATE SKIP LOCKED` so concurrent runs are safe.
   2. Build a single classification prompt per memory using the YAML type definitions.
   3. Call OpenRouter with structured-output JSON mode; parse and validate against a Pydantic schema.
   4. For each classification with confidence ≥ 0.7, write to the corresponding specialized table with `enrichment_version` stamped.
   5. Mark the memory `enriched = true`, `enriched_at = now()`, `enriched_version = N`. On failure, set `enrichment_error` and leave `enriched = false` so the next run retries.
3. **Prompt config** at `server/prompts/classify.v1.yaml`:
   - One block per type with definition, 2–3 few-shot examples, and the field schema.
   - Top-level `enrichment_version: 1`. Bumping the version is the only way to trigger selective re-enrichment.
4. **Selective re-enrichment CLI**: `python -m grove.enrichment.reset --version-below N` flips matching memories back to `enriched = false`.
5. **Per-memory cap**: skip enrichment for memories above ~8 000 tokens with a recorded error to keep classification cost bounded; revisit at monthly review if it bites.
6. **Observability**: each run logs counts per type, average confidence, error count, total tokens, total cost — saved both to `enrichment_state.notes` (JSON) and structured logs.

### Exit criteria

- Hourly cron runs visibly in `enrichment_state`; 95% of memories enriched within 2 h of capture (PRD §6.7 KPI).
- Bumping `enrichment_version` and running `reset --version-below 2` re-classifies prior memories without touching the general table.
- Failed LLM call on memory N does not block memory N+1.

---

## Phase 5 — Polish

**Goal:** V1 is durable, debuggable, and pleasant to use daily.

### Tasks

1. **Offline / sync edge cases**:
   - Token expiry / 401 → settings screen prompts re-paste.
   - Permanent 4xx → `failed` state with surfaced error in a debug screen; never silent.
   - Sweep retries with exponential backoff capped at 1 h.
2. **Capture polish**:
   - Filler-word cleanup toggle for dictated text (configurable; default off).
   - Detected-language preview before send.
   - Character/token count indicator.
3. **Retrieval polish**:
   - Show recent queries (read from `query_logs`) for tap-to-rerun.
   - "Open source memory" expand/collapse with smooth transitions.
4. **Settings screen**: server URL, bearer token, capture defaults, "force resync" button, build/version info.
5. **Server hardening**:
   - Per-token rate limit (single-user, but defends against runaway client bugs).
   - OpenRouter monthly spend cap + alert (PRD §9 risk).
   - 30-day query-log review SQL committed to `server/scripts/weekly_review.sql` and `monthly_review.sql` for the §11 review rituals.
6. **Deletion flow** verified end-to-end: iOS delete → cascade through chunks + specialized tables → query logs preserved with NULL FK.
7. **Backup drill** documented in `ops/RUNBOOK.md`: restore to a scratch box, sanity-check counts.
8. **Privacy posture doc** in `docs/privacy.md` capturing exactly what leaves the box and to whom (per PRD §7.3), so it's revisitable.

### Exit criteria — V1 ship gate

All Phase 1 KPIs from PRD §4 hit on real personal use over 14 consecutive days:

- ≥ 3 captures/day with no prompting
- 99%+ capture success rate
- < 5 s retrieval round-trip
- ≥ 95% enrichment within 2 h
- < 2 s perceived capture friction

---

## Cross-cutting concerns

**Secrets.** Hetzner box has a single `.env` loaded by docker-compose: `BEARER_TOKEN`, `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `DATABASE_URL`. Never committed; sample `.env.example` in repo.

**Cost monitoring.** OpenRouter spend cap + a tiny `/v1/admin/usage` endpoint summarising `query_logs` token totals and `enrichment_state` token totals for the current month. Surfaced in a single CLI script, no UI.

**Testing strategy.**
- Server: pytest with a real Postgres+pgvector via testcontainers; mock only the OpenAI/OpenRouter HTTP boundary.
- iOS: XCTest for the local-store + sync state machine; manual on-device for capture UX.
- One end-to-end smoke test that captures a synthetic memory, runs the enrichment worker once, and queries for it.

**Versioning everything that can drift.** `embedding_model` per row, `enrichment_version` per memory and per specialized record, `prompts/*.v{N}.yaml` files, `synthesis_model` on every query log. Re-embedding and re-enrichment are config + cron, not migrations.

**What's intentionally not built in V1.** Browse UI, edit/append, attachments, share sheet, MCP, multi-device, V2 relationship linking, V3 pattern synthesis. The architecture supports them — see PRD §13 — but none of them ship.

---

## Suggested calendar

Rough effort estimate, evenings/weekends, single developer:

| Phase | Estimate |
|---|---|
| 1 — Server infra | 1 week |
| 2 — Capture path | 2 weeks (iOS dominates) |
| 3 — Retrieval path | 1.5 weeks |
| 4 — Enrichment | 1 week |
| 5 — Polish + 14-day soak | 2–3 weeks |
| **Total to V1 ship gate** | **~7–9 weeks** |

---

## Decisions still to make at implementation time

- Specific synthesis model on OpenRouter (start with one Haiku-class, A/B against GPT-4o-mini after 100 queries).
- Exact refinement-detection thresholds — ship with 5 min / cosine 0.85, tune from data.
- Whether to add a small `topics` free-form table later if the four prototype tables miss too much; explicitly a monthly-review decision, not a launch decision.
