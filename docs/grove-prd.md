# The Oracle — Product Requirements Document

**Status:** Draft v0.3
**Working name:** The Oracle (WIP)
**Author:** Mark
**Last updated:** 2026-05-09

**Changes from v0.2:** Moved enrichment into V1 scope (was previously deferred). Added forward-compatibility section detailing how V1 enrichment is designed to support V2 (relationship linking) and V3 (temporal pattern synthesis) without schema migrations or refactoring. Reorganized so enrichment is treated as a first-class V1 component rather than a future addition.

---

## 1. Summary

The Oracle is a personal memory and thought-capture system. It accepts text inputs of varying lengths — from short captures to long-form emails and meeting notes — stores them with semantic embeddings, and exposes a conversational retrieval interface that synthesizes answers grounded in the user's own captured content.

The product is built for a single user (the author) on iOS, backed by a server that handles persistence, embedding, retrieval-augmented synthesis, and asynchronous enrichment. The architecture leans on the iPhone for capture-time intelligence and on the server for corpus-level storage, search, and analysis.

Three core design tenets shape the architecture:

**Additive schema evolution.** Every memory lands in a general catch-all table at capture time. Specialized tables emerge over time as patterns are observed in actual content, never as predictions made upfront. Specialized tables are always derived from the general table — they annotate or structure existing memories, never replace them. The general table is the immutable source of truth.

**Observability of usage.** Every retrieval query is logged. Query logs provide the signal needed to evaluate which parts of the system are earning their weight, which patterns are emerging in actual use, and which schema changes are justified by evidence.

**Iterative enrichment.** Enrichment runs from V1 onward — not as a future addition, but as a core part of the system. It classifies captured memories into specialized tables based on configurable logic. The enrichment process is designed for forward compatibility, allowing V2 (relationship linking) and V3 (temporal pattern synthesis) to be added without schema migrations or data loss.

This PRD scopes the V1 proof-of-concept. Multi-user, sharing, and productization concerns are explicitly out of scope.

## 2. Goals

V1 is a personal proof-of-concept to validate three things in priority order:

1. **Capture friction is low enough for daily use.** The capture flow must be fast enough and cognitively cheap enough that the user actually uses it without thinking. A capture tool that isn't used has zero value regardless of how clever the retrieval is.
2. **Retrieval surfaces ideas and connections the user wouldn't have made on their own.** Once enough varied content is captured, the conversational retrieval should produce answers and synthesis that demonstrate value beyond simple keyword search or memory.
3. **The system handles varied input volumes.** Short notes (under 100 words) and long-form content (emails, meeting notes, articles up to several thousand words) should both be first-class inputs without separate flows.

A secondary goal: V1 must produce sufficient signal (via query logs and enrichment outcomes) to make informed decisions about V2 and V3 features. Enrichment exists in V1 specifically to enable schema iteration based on real data.

## 3. Non-goals

The following are explicitly out of scope for V1 and will be revisited only after V1 success criteria are met:

- Multi-user support, authentication beyond a single owner, or sharing
- Attachments of any kind (images, PDFs, audio files as stored objects)
- Mutable memories — memories are append-only after capture
- Integrations with third-party services (Gmail, calendars, browser extensions, Obsidian, etc.)
- MCP server exposure of the memory store
- iPad and Mac clients — iPhone only for V1
- Public distribution or App Store release — TestFlight or development builds only
- Voice as a stored medium — voice is an input modality but is transcribed to text immediately
- Image and PDF ingestion
- Hierarchical organization, folders, or notebooks
- User-defined tags as a primary organizational system
- Memory-to-memory relationship linking — this is a V2 feature
- Temporal pattern synthesis and insight generation — this is a V3 feature
- Browse-mode UI (timelines, graphs, structured navigation) — V1 retrieval is conversational only

## 4. Success criteria and KPIs

V1 success is staged, since some KPIs require accumulated content to evaluate.

### Phase 1 KPIs (validates infrastructure and UX)

Evaluated with low-stakes or synthetic content while the user develops trust in the system.

- **Capture latency.** From triggering capture to confirmed save (locally), under 2 seconds in the common case. Background sync to server may take longer; this measures perceived friction.
- **Capture success rate.** 99%+ of captures reach the server eventually, including those triggered while offline or during phone-lock transitions.
- **Daily capture habit.** User captures at least 3 thoughts per day for 14 consecutive days without prompting.
- **Retrieval responsiveness.** Conversational queries return synthesized answers within 5 seconds end-to-end on a healthy network.
- **Enrichment reliability.** 95%+ of memories are successfully enriched within 2 hours of capture (allowing for the hourly batch cadence and one retry).

### Phase 2 KPIs (validates product value)

Evaluated only after Phase 1 KPIs are met and user has populated the system with real content.

- **Connection-surfacing.** In a structured weekly retrospective, user identifies at least one connection or insight per week that the system surfaced and the user would not have made unaided.
- **Trust threshold.** User chooses to capture content that previously went elsewhere (Apple Notes, Obsidian, etc.) for at least 30 consecutive days.
- **Multi-volume coverage.** User captures content of varied lengths (short and long) across the week, with no length-based avoidance behavior.
- **Schema evolution signal.** Query logs reveal at least one clear pattern that justifies a new or modified specialized table within 60 days of regular use.

## 5. User and use cases

Single user: the author. Primary device is an iPhone 17 running the latest iOS.

### Primary use cases

- **Quick capture of a passing thought.** "I should think more about X." A few seconds, maybe one sentence, then phone gets locked and pocketed.
- **Capture of a longer reflection.** A paragraph or two written intentionally — synthesis of a meeting, reaction to an article, working through a problem.
- **Capture of imported long-form content.** A meeting transcript pasted in, a long email forwarded as text, an article excerpt. Several hundred to several thousand words.
- **Conversational retrieval.** "What have I been thinking about regarding the Drupal caching work?" The system finds relevant memories and synthesizes a response grounded in them.
- **Exploratory retrieval.** "Have I had thoughts that connect to this idea?" — open-ended queries where the user is fishing for connections.
- **Targeted retrieval.** "What did I capture about the Island Health GTM work?" — user knows roughly what they're looking for.

## 6. Functional requirements

### 6.1 Capture

V1 must support text capture from the iPhone. The specific entry points are an open design question (see §10), but the capture flow must:

- Accept text input from typing or voice dictation (using on-device Speech framework where available)
- Support capture of inputs ranging from a few words to several thousand
- Save the capture to a local store immediately, before any network activity
- Initiate background sync to the server using a mechanism that survives the user locking the phone immediately after sending
- Provide visual confirmation that the capture was accepted locally
- Function fully offline — captures should queue and drain when connectivity returns

### 6.2 On-device pre-processing

The phone performs lightweight intelligence work before sending captures to the server. This reduces server cost, improves privacy, and lets the phone deliver immediate UI feedback. For V1, on-device processing covers:

- Voice-to-text transcription for voice inputs
- Light cleanup of dictated text (filler word removal as a configurable option)
- Extraction of basic metadata at capture time:
  - Capture timestamp
  - Source modality (typed vs. dictated)
  - Approximate character and token count
  - Detected language

More sophisticated on-device classification (intent detection, entity extraction, topic tagging) is deferred to a later phase. V1 keeps on-device work minimal to ship faster.

### 6.3 Server-side processing (capture path)

The server, on receiving a capture:

- Stores the raw text and metadata in the general `memories` table
- Generates a vector embedding using a configurable embedding model (default: OpenAI text-embedding-3-small)
- For long content (over a configurable token threshold, default 500 tokens), chunks the content before embedding and stores embeddings per chunk linked to the parent memory
- Stores the embedding alongside or linked to the memory record
- Marks the memory as unenriched (`enriched = false`)
- Returns confirmation to the client

Enrichment runs separately on a schedule (see §6.4). Capture does not block on enrichment.

### 6.4 Enrichment (V1, in scope)

The enrichment process is a scheduled background job that classifies general-table memories into specialized tables. It runs hourly by default and processes only memories where `enriched = false`.

**Enrichment is in V1 scope** because the additive schema evolution principle requires real classified data to iterate against. Without enrichment running, query logs cannot surface meaningful signal about which specialized tables are useful.

V1 enrichment ships with a small number of prototype specialized tables — initial candidates include `decisions` and `people_interactions`, but the final selection is an open question (§10) to be answered based on the user's anticipated capture patterns. The expectation is explicit: these prototype tables will evolve, get replaced, or be deprecated based on evidence from real use. They are not committed schema.

The enrichment flow:

1. Hourly cron triggers the enrichment worker
2. Worker queries memories where `enriched = false`, processes in batches
3. For each memory: worker calls a classification model with memory content and the current type definitions
4. For each classification with confidence above threshold (default 0.7), worker writes a record to the corresponding specialized table
5. Worker marks the memory `enriched = true` and stamps `enriched_at` and `enriched_version`
6. Worker logs run statistics (memories processed, classifications by type, errors)

V1 specialized tables are designed for forward compatibility (see §13).

### 6.5 Retrieval

V1 exposes a single retrieval surface: conversational query. The flow is:

- User types a natural-language question on the phone
- Phone optionally performs query reformulation or expansion on-device (deferred — V1 sends the raw query)
- Phone sends the query to the server
- Server creates a query log entry (see §6.7)
- Server embeds the query and performs vector similarity search against the corpus, returning top-N matching memories or chunks
- Server may also query specialized tables based on query intent (V1: simple — always queries `memories` table; specialized table querying is left as an open implementation question for V1, with the architecture designed to support it)
- Server passes the user's query and retrieved memories to a chat model with a system prompt that produces a synthesized answer grounded in the retrieved content, with inline references back to the source memories
- Server updates the query log with returned memory IDs, synthesis cost, and other outcome data
- Phone displays the synthesized answer with the ability to expand and view the underlying source memories
- Phone optionally captures user feedback on retrieval quality (helpful / not helpful) and sends it to update the query log

Direct keyword or filter-based search is out of scope for V1. The conversational interface is the only retrieval path.

### 6.6 Memory lifecycle

- Memories are immutable after capture for V1 (no edit, no append, no version history)
- Users can delete a memory permanently. Deletion removes the memory record, all associated chunks, embeddings, and any specialized table records that reference it. No soft delete, no undo
- Deletion is initiated from a memory detail view accessible from retrieval results
- Query logs are retained even when the underlying memories they reference are deleted — the log entry preserves the query and outcome metadata, but foreign key references to deleted memories become null

### 6.7 Query logging

Every retrieval query is logged for the purpose of understanding usage patterns and informing schema evolution. The query log captures:

- Timestamp
- Query text (the user's natural language question)
- Query embedding (vector representation, for clustering and pattern analysis over time)
- Tables searched (V1: at minimum `memories`; specialized tables when implemented in retrieval)
- Number of results returned
- IDs of memories returned in results
- Synthesis model used and approximate token cost
- User feedback on result quality (optional, captured post-retrieval)
- Whether this query appears to be a refinement of a recent query (detected heuristically — similar query within a short window)

Query logs are owned data, treated at the same privacy level as memory content. They are subject to the same backup, retention, and deletion policies as memories.

The log is not displayed in the V1 UI. It exists for analytical use during weekly and monthly reviews (see §11), and may be surfaced in a future admin or insights interface.

### 6.8 Offline-first behavior

The local data store on the phone is the source of truth for unsynced captures.

- Every capture writes to local storage (Core Data or SwiftData) before any network attempt
- Each captured memory has a sync state: pending, syncing, synced, failed
- The UI never blocks on the network for capture
- On app launch and on network connectivity changes, the app sweeps for unsynced captures and re-attempts upload
- Background uploads use URLSession with a background configuration so they survive app suspension

### 6.9 Authentication

V1 uses a single long-lived bearer token stored in the iOS Keychain. The token is configured manually during setup and is not user-rotatable from within the app. The server validates the token on every request. No user accounts, no login flow, no password reset.

## 7. Non-functional requirements

### 7.1 Performance

- Capture write to local store: under 100ms
- Capture write to local store and queue for upload: under 500ms
- Conversational retrieval round-trip: under 5 seconds on a healthy network for a corpus under 10,000 memories
- Vector search alone: under 500ms server-side for a corpus under 10,000 memories
- Enrichment processing: not user-facing; runs on hourly schedule with no perceived latency expectation. Individual memory enrichment should complete within 30 seconds (LLM call plus database writes)

### 7.2 Reliability

- Captured memories must not be lost. The local store is durable; server sync is eventually consistent
- Backups of the server-side database run at least daily, retained for at least 30 days. Backups include memories, memory chunks, specialized tables, and query logs
- The system tolerates server downtime — the phone continues to capture, queueing for later upload
- The enrichment process is resumable — partially-processed batches can be re-run without producing duplicate classifications
- Enrichment failures are non-blocking — a failed classification on one memory does not prevent capture, retrieval, or enrichment of other memories

### 7.3 Privacy posture

V1 accepts the use of trusted third parties for cost and flexibility reasons. Specifically:

- Embedding generation may use a third-party API (OpenAI or similar) — embeddings of memory content leave the user's infrastructure
- Conversational synthesis may use a third-party LLM API — full text of relevant memories is sent to the synthesis provider per query
- Classification (enrichment) uses a third-party LLM API — full memory content is sent to the classification provider during enrichment runs
- Database storage may be self-hosted or use a managed Postgres provider
- Query logs are stored at the same trust level as memories. They reveal user thinking patterns and are subject to the same posture as memory content itself

The privacy posture is documented and revisitable. A V2 may move embeddings, synthesis, or classification to local or self-hosted providers.

### 7.4 Cost

Target ongoing operating cost: $5-10/month, with a hard ceiling of $20/month including amortization of any hardware purchased specifically for this project.

Estimated V1 monthly cost breakdown:
- Embedding (text-embedding-3-small): under $1/month at personal volume
- Synthesis (chat model for retrieval): $2-5/month at moderate query volume
- Classification (enrichment): $0.30-1/month at personal capture volume
- Hosting: variable based on topology choice (§8.4); $0-12/month
- Backup storage: $0-6/month

### 7.5 iOS target

- iOS 26+ (latest at time of writing)
- iPhone 17 as the reference development device
- Foundation Models framework available but not relied upon for V1 — kept as an option for later on-device processing

## 8. Architecture

### 8.1 High-level components

The system has five logical components:

1. **iOS client** (Swift/SwiftUI app on iPhone)
2. **Backend API** (HTTP service handling auth, capture, retrieval, and query logging)
3. **Database** (Postgres with pgvector) — holds memories, chunks, specialized tables, query logs, and enrichment state
4. **Enrichment worker** (scheduled job that classifies memories into specialized tables)
5. **Third-party AI services** (embedding model API, chat model API for both synthesis and classification)

### 8.2 Data flow

**Capture flow:**

```
User captures text on phone
  → Phone writes to local store (Core Data/SwiftData), marks pending
  → Phone enqueues background URLSession upload
  → Backend receives upload, stores raw memory in Postgres (memories table, enriched=false)
  → Backend calls embedding API, stores embedding(s) in Postgres
  → Backend returns success
  → Phone marks local memory as synced
```

**Enrichment flow (hourly):**

```
Cron triggers enrichment worker
  → Worker queries memories WHERE enriched = false
  → For each memory (in batches):
    → Worker loads classification config (types, prompts, thresholds)
    → Worker calls classification model
    → Worker writes records to specialized tables for each classification above threshold
    → Worker marks memory enriched = true, stamps enriched_at and enriched_version
  → Worker writes enrichment run summary to enrichment_state table
```

**Retrieval flow:**

```
User types query on phone
  → Phone sends query to backend
  → Backend creates query_log entry with query text and embedding
  → Backend embeds query via embedding API
  → Backend performs vector similarity search in Postgres
  → Backend retrieves top-N matching memories/chunks
  → Backend constructs prompt: query + retrieved content + system instructions
  → Backend calls chat model API for synthesis
  → Backend updates query_log with returned memory IDs and synthesis cost
  → Backend returns synthesized answer with source memory references
  → Phone displays answer with expandable sources
  → User optionally provides feedback; phone sends to backend; backend updates query_log
```

### 8.3 Data model (V1)

V1 ships with the following tables: `memories`, `memory_chunks`, `query_logs`, `enrichment_state`, and one or more prototype specialized tables (initial candidates: `decisions`, `people_interactions`).

```sql
memories (
  id UUID PRIMARY KEY,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_modality TEXT,            -- 'typed' | 'dictated'
  source_device TEXT,              -- e.g. 'iPhone 17'
  language TEXT,                   -- detected language code
  token_count INTEGER,
  embedding_model TEXT,            -- name/version of model used
  embedding VECTOR(1536),          -- null if content is chunked
  client_id UUID NOT NULL UNIQUE,  -- UUID generated on phone, idempotency key
  enriched BOOLEAN NOT NULL DEFAULT false,
  enriched_at TIMESTAMPTZ,         -- timestamp of last enrichment run
  enriched_version INTEGER,        -- version of enrichment pipeline that processed this memory
  enrichment_error TEXT            -- if enrichment failed, the reason
)

memory_chunks (
  id UUID PRIMARY KEY,
  memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL,
  content TEXT NOT NULL,
  embedding VECTOR(1536) NOT NULL,
  embedding_model TEXT NOT NULL
)

query_logs (
  id UUID PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  query_text TEXT NOT NULL,
  query_embedding VECTOR(1536),
  tables_searched TEXT[] NOT NULL,
  result_count INTEGER NOT NULL,
  returned_memory_ids UUID[],
  synthesis_model TEXT,
  synthesis_input_tokens INTEGER,
  synthesis_output_tokens INTEGER,
  user_feedback TEXT,                        -- 'helpful' | 'not_helpful' | null
  feedback_at TIMESTAMPTZ,
  is_refinement BOOLEAN DEFAULT false,
  parent_query_id UUID REFERENCES query_logs(id)
)

enrichment_state (
  id UUID PRIMARY KEY,
  run_started_at TIMESTAMPTZ NOT NULL,
  run_completed_at TIMESTAMPTZ,
  pipeline_version INTEGER NOT NULL,
  memories_processed INTEGER NOT NULL DEFAULT 0,
  classifications_created INTEGER NOT NULL DEFAULT 0,
  errors INTEGER NOT NULL DEFAULT 0,
  notes TEXT
)

-- Example V1 prototype specialized table:
decisions (
  id UUID PRIMARY KEY,
  memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  decision_maker TEXT,
  context TEXT,
  options TEXT[],
  chosen_option TEXT,
  rationale TEXT,
  outcome TEXT,
  outcome_date DATE,
  confidence FLOAT NOT NULL,         -- enrichment confidence
  enrichment_version INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)

-- Example V1 prototype specialized table:
people_interactions (
  id UUID PRIMARY KEY,
  memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  person_name TEXT NOT NULL,
  interaction_medium TEXT,           -- 'in-person' | 'call' | 'email' | 'message' | 'async'
  topics TEXT[],
  next_steps TEXT[],
  confidence FLOAT NOT NULL,
  enrichment_version INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
```

The `client_id` UUID is generated on the phone at capture time and serves as an idempotency key — if the same capture is uploaded twice (network retry, phone wake from suspended upload), the server treats the second upload as a no-op via the UNIQUE constraint.

The `embedding_model` field per row enables future re-embedding strategies — old rows can be identified and re-embedded selectively when models change.

The `enriched_version` field on memories and specialized tables enables selective re-enrichment when classification logic changes.

### 8.4 Deployment topology — three options

The backend, database, and third-party AI services can be hosted in several configurations within budget. The PRD does not pick one — this is a decision point during implementation.

**Option A: Mini PC self-hosted**

A dedicated mini PC (Intel N100 or similar, 16GB RAM, 500GB NVMe) at home runs Postgres, the backend API, Caddy as a reverse proxy, and the enrichment worker as a cron job. Third-party APIs are still used for embedding, synthesis, and classification. Bootstrap cost: 280-400 CAD. Ongoing cost: roughly 1-2 CAD/month electricity + 4-6 CAD/month offsite backup + ~5 CAD/month API spend = under 15 CAD/month all-in. Amortization over 5 years adds another 5-7 CAD/month.

Trade-offs: full control of the database, no SaaS dependencies for storage, requires home network exposure (Tailscale recommended), home internet outages affect the system, user owns ops.

**Option B: Rented box (Hetzner)**

A small Hetzner Cloud instance (CX22, 2 vCPU, 4GB RAM) runs the same stack: Postgres, backend API, Caddy, enrichment worker as cron. Third-party APIs handle embedding, synthesis, and classification. Ongoing cost: ~6 CAD/month server + ~6 CAD/month API spend = ~12 CAD/month. No bootstrap hardware cost. No amortization concern.

Trade-offs: someone else's infrastructure, no home network exposure, slight latency depending on region, predictable monthly cost, easier to walk away from if the project doesn't pan out.

**Option C: Supabase managed**

Supabase free tier (or Pro at 25 USD/month if outgrown) provides Postgres with pgvector, edge functions for the backend logic, and a managed REST API. Scheduled enrichment runs as a Supabase scheduled function or external cron triggering an edge function. Third-party APIs still handle embedding, synthesis, and classification (OpenRouter or direct). Free tier handles personal volume comfortably. Ongoing cost: ~6 CAD/month API spend on free tier; ~30+ USD/month if upgraded to Pro.

Trade-offs: minimum infrastructure work, generous free tier for personal scale, vendor lock-in to Supabase's edge function runtime (Deno), still your data but in someone else's database.

A recommendation among these will be made at implementation time based on weighing the user's priorities. All three fit within the $5-20/month budget.

### 8.5 Third-party AI services

V1 defaults:

- **Embedding:** OpenAI text-embedding-3-small (1536 dimensions, ~$0.02 per million tokens). Personal-volume cost is well under $1/month.
- **Synthesis:** A cheap chat model — candidates include Claude Haiku, GPT-4o-mini, or similar at 15-25 cents per million input tokens. RAG queries with retrieved context may run higher token counts; budget $2-5/month for moderate use.
- **Classification (enrichment):** Same cheap chat model, called per-memory during enrichment. At personal capture volume (20-50 memories/day), classification cost is well under $1/month.
- **Routing:** OpenRouter is recommended as a gateway, since it lets the system swap underlying models without code changes and provides a single billing relationship.

## 9. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Capture friction is still too high; user doesn't form the habit | Medium | High | Aggressively measure Phase 1 KPI; iterate on capture entry point quickly |
| Retrieval quality is poor due to embedding model limitations | Medium | High | Bake re-embedding capability in from day one; allow model swap without data loss |
| Long-content chunking produces poor results | Medium | Medium | Make chunking strategy configurable; experiment with chunk size and overlap |
| Background upload fails silently | Low | High | Local store is source of truth; sweep on launch catches stragglers |
| Cost exceeds budget due to LLM synthesis or classification | Low | Medium | Set monthly spend caps on OpenRouter; monitor usage |
| Server downtime blocks retrieval | Medium | Low | Capture continues offline; retrieval is intentionally online-only for V1 |
| Trust in trusted third parties is misplaced | Low | Medium | Privacy posture is explicitly documented; V2 can migrate to self-hosted embedding/synthesis |
| Vendor lock-in (especially Supabase) becomes painful | Low | Medium | Data model is plain Postgres; export and migration are straightforward |
| Schema evolution leads to chaos with too many specialized tables | Medium | Low | Monthly review enforces sunset of unused tables; query logs reveal what's not earning weight |
| Query logs grow unbounded | Low | Low | Personal-scale volume keeps logs negligible (10-20MB per year); revisit if hosting changes |
| Enrichment worker fails or produces poor classifications | Medium | Low | Enrichment is async; failures don't block capture or retrieval; classifications are revisable by re-running with updated prompts |
| Initial V1 prototype tables are wrong choice | High | Low | Tables are explicitly prototypes; deletion is no-cost; iteration via monthly review |

## 10. Open questions

These are deliberately deferred and will be answered during implementation.

- **Capture entry point.** Action Button into a dedicated capture screen, share sheet from other apps, both, or something else? V1 needs at least one entry point but the choice should be informed by which feels lowest-friction in practice.
- **Synthesis model selection.** Claude Haiku vs. GPT-4o-mini vs. another option. Should be evaluated empirically on retrieval quality.
- **Classification model selection.** May be the same as synthesis model or different. Cost vs. quality trade-off.
- **Chunking strategy for long content.** Fixed token windows, sentence boundaries, paragraph boundaries, or semantic chunking. V1 should ship with one and revisit.
- **Hosting topology.** Mini PC vs. Hetzner vs. Supabase. To be decided based on weighing trade-offs documented in §8.4.
- **Initial V1 specialized tables.** Which prototype tables to ship with — `decisions` and `people_interactions` are tentative, but the final selection should be informed by the user's anticipated capture patterns.
- **Specialized table querying in retrieval.** Whether V1 retrieval queries specialized tables in addition to the general `memories` table, or only the general table. Architecture supports either; decision is about scope and complexity for V1.
- **Refinement detection heuristic.** What window and similarity threshold define a query as a refinement of a previous one? V1 ships with a simple heuristic and tunes from observed data.

## 11. Schema evolution and review cadence

The Oracle is designed to grow its data model based on observed patterns rather than upfront prediction. This requires regular but lightweight review rituals.

### Review cadence

**Weekly review (~15 minutes, every Friday).** User reviews:
- Captures from the past week — what types of content did I save?
- Query logs from the past week — what was I trying to find? Did I find it?
- Enrichment results from the past week — what was classified, what was missed, were classifications accurate?
- Patterns or themes emerging in any of the above

The output of weekly review is informal: noticing patterns, noting potential specialized tables to consider, identifying friction points in capture, retrieval, or enrichment.

**Monthly review (~30 minutes, first weekend of the month).** User considers:
- Should any prototype specialized tables be promoted to permanent schema?
- Are any specialized tables not earning their weight? Sunset candidates.
- Are there changes to existing tables (new fields, restructured fields) that the past month's data suggests?
- What changes to enrichment prompts or classification logic should be made?
- Should re-enrichment be triggered for any existing memories with the updated logic?

**Quarterly review (~60 minutes, every 3 months).** User considers:
- Larger architectural questions: is the embedding model still appropriate? Is the hosting topology still right? Is the synthesis model performing?
- Bigger schema migrations or refactors
- Whether V2 (relationship linking) or V3 (temporal pattern synthesis) features have earned their way onto the roadmap based on observed signal
- Whether new features outside the enrichment story (mutable memories, attachments, integrations, etc.) have earned their way onto the roadmap

### Decision principles

- **Adding is cheap, deleting is fine.** Specialized tables can be created to test a hypothesis. If the hypothesis doesn't hold, delete the table — the underlying memories are untouched.
- **Query logs are the north star.** What the user actually queries is more reliable signal than what they think they'll query.
- **The general table is sacred.** Anything that risks the general `memories` table is rejected. Specialized tables are always derived.
- **Schema changes are reversible.** If a change doesn't work out, the data lives elsewhere and can be reconstructed.
- **Enrichment is versioned.** Changes to classification logic produce new `enriched_version` values. Old classifications coexist with new until you choose to re-enrich.

## 12. Phasing

V1 ships as a single coherent release covering everything in §6, including enrichment. Suggested implementation order:

1. **Server infrastructure.** Postgres with pgvector, schema (memories, memory_chunks, query_logs, enrichment_state, prototype specialized tables), basic backend API with auth, deployed in chosen topology
2. **Capture path.** iOS app skeleton, local store, capture screen, background upload, server-side ingest endpoint with embedding generation
3. **Retrieval path.** Server-side vector search, query logging, RAG synthesis endpoint, iOS retrieval UI, optional feedback capture
4. **Enrichment.** Hourly cron job, classification config, prompt design, specialized table writes, enrichment state tracking
5. **Polish.** Offline edge cases, error handling, deletion flow (with cascade to specialized tables and query log references), sweep on launch, basic settings

V2 introduces:
- Memory-to-memory relationship linking via a new `memory_relationships` table (additive, no existing schema changes)
- Enrichment pipeline extension to extract and link relationships
- Retrieval extension to optionally surface related memories

V3 introduces:
- Temporal pattern synthesis jobs (weekly/monthly cron) that scan corpus and query logs for emerging insights
- Optional surfacing of insights in retrieval ("you've made similar decisions before")
- Possibly an admin/insights interface for reviewing patterns

V2 and V3 scopes are deliberately not nailed down in this document. They will be defined after V1 KPIs are evaluated and reviews surface concrete patterns. §13 documents how V1 is designed to support them without future schema migrations.

## 13. V1 enrichment design with forward compatibility for V2 and V3

This section documents how V1 enrichment is architected to support the eventual evolution toward V2 (relationship linking) and V3 (temporal pattern synthesis). The goal is to avoid schema migrations or refactoring when those phases arrive.

### 13.1 Data model forward compatibility

**Fields on `memories` that V1 uses and V2/V3 inherit:**

- `enriched` (boolean) — tracks whether enrichment has run
- `enriched_at` (timestamp) — when enrichment occurred
- `enriched_version` (integer) — which version of the enrichment pipeline ran
- `enrichment_error` (text, nullable) — failure reason if enrichment errored

These fields don't change in V2 or V3. The enrichment pipeline grows new steps; the memory tracking remains the same.

**Specialized tables include from V1:**

- Foreign key back to source memory via `memory_id`
- Cascade deletion (deleting a memory removes its specialized records)
- All extracted structured fields as separate columns — not stuffed into a single JSON blob — so they're queryable, indexable, and joinable
- `confidence` score per record
- `enrichment_version` per record, matching the version in `memories`
- `created_at` timestamp

This structure means V2 can join across specialized tables on entity values (e.g., `WHERE person_name = 'Sarah'`) without schema changes.

### 13.2 Enrichment pipeline architecture

**Design principle:** Enrichment logic lives in configuration and prompts, not hard-coded application logic.

**The V1 enrichment job is structured as a pipeline of discrete steps:**

1. **Fetch** unprocessed memories (`WHERE enriched = false`)
2. **Classify** each memory by calling the LLM with the configured classification prompt
3. **Extract** structured fields for each classification with confidence above threshold
4. **Write** records to specialized tables
5. **Mark** memories as enriched and stamp version

Each step is independently testable and replaceable. The pipeline runs synchronously for one memory but can process multiple memories in parallel batches.

**V2 extends the pipeline by adding a step:**

6. **Link relationships** — for newly enriched memories, query existing specialized table records for matching entities (same person name, same topic, same decision context) and write rows to a new `memory_relationships` table

V2 doesn't modify steps 1-5. It adds step 6 after them.

**V3 adds further steps:**

7. **Detect patterns** — periodic (not hourly) job that analyzes recent enriched memories and relationships for temporal patterns or recurring themes
8. **Surface insights** — write detected patterns to an `insights` table for retrieval-time consumption

V3 also runs separately from the per-memory pipeline. It operates on the corpus.

### 13.3 Classification prompt design for extensibility

V1 ships with a classification prompt structured to support easy addition of new types in V2. The prompt is parameterized over the list of types, their definitions, and their extracted fields. Adding a new specialized table in V2 (or modifying one) is a config change, not a code change.

**Conceptual prompt structure:**

```
System: Classify this memory into zero or more of these types:
- decisions: [definition + examples]
- people_interactions: [definition + examples]
- (future types added here)

For each type with confidence >= 0.7, extract the following fields:
- decisions: [list of fields]
- people_interactions: [list of fields]

Return JSON:
{
  "classifications": [
    {"type": "...", "confidence": 0.85, "extracted_fields": {...}}
  ]
}
```

**Why this matters for evolution:**

- New types can be added to the prompt without rewriting it
- Each type owns its own field extraction logic, so types don't interfere
- Confidence scores let thresholds be tuned per-type
- The prompt itself can be versioned (`enrichment_version`), so changes are tracked

### 13.4 Query log integration with enrichment

V1 query logs include enrichment metadata that V2/V3 use for analysis:

- `tables_searched` array shows which specialized tables participated in the query
- `returned_memory_ids` preserves order of results
- The `enriched_version` of returned memories can be looked up at analysis time

V2 and V3 use these logs to measure whether enrichment changes improve retrieval. For example:
- Are queries hitting specialized tables more often than the general table?
- Did query satisfaction (`user_feedback`) improve after the latest classification prompt update?
- Which specialized tables appear most in successful queries?

### 13.5 Migration path: V1 → V2 (relationship linking)

When V2 is built, the data model requires zero changes:

1. Create `memory_relationships` table (new, doesn't touch existing schemas)
2. Add a relationship-linking step to the enrichment pipeline (config + code)
3. Backfill: re-run enrichment on existing memories to extract relationships (no data loss; existing classifications are preserved)
4. Update retrieval to optionally follow relationships (config flag, default off until validated)

No schema migrations on existing tables. Existing data remains valid.

### 13.6 Migration path: V2 → V3 (temporal patterns and synthesis)

V3 adds analytical jobs that read existing data:

1. Create `insights` and `patterns` tables (new, additive)
2. Write cron jobs for weekly and monthly pattern analysis
3. Update retrieval to optionally surface patterns ("similar to past hiring decisions")

Again, no migrations to existing tables. V3 is additive analysis on top of existing storage.

### 13.7 Operational considerations for V1

**Enrichment failure modes and recovery:**

- If LLM call fails: mark memory `enriched = false, enrichment_error = [reason]`. Job will retry on next run.
- If classification produces bad result: user can manually delete the specialized record; memory in general table is untouched
- If classification logic changes: bump `enrichment_version`; old records coexist with new; user can selectively re-enrich

**Selective re-enrichment:**

When the classification prompt changes:
- Set `enriched = false` on memories with old `enriched_version`
- Next enrichment run picks them up and re-processes with new logic
- Old specialized table records can be deleted, replaced, or kept based on intent (governed by enrichment config)

**Monitoring:**

- `enrichment_state` table tracks each run's stats
- Monthly review reads enrichment state plus query logs to evaluate health
- Failed enrichments accumulate visibly via `enrichment_error` field on memories

### 13.8 Code organization recommendations

To support V2/V3 cleanly, V1 should:

- Separate enrichment code from API code (different modules or services)
- Keep classification prompts in version-controlled config files, not embedded in code
- Treat specialized table definitions as schema migrations, with each table getting its own migration file (easier to drop or alter individually)
- Log enrichment runs in structured form (JSON or DB rows), not just stdout, so V2/V3 can read history programmatically

### 13.9 The principle behind all of this

V1 is conservative in scope (only what's needed to validate the core loop) but architecturally prepared (no painted-in corners). Every schema field, every log, every modular boundary is justified either by V1 use or by clear V2/V3 need. Anything else is deferred.

The goal: when V2 or V3 work begins, the answer to "is this hard?" is consistently "no, the V1 architecture already supports it."

---

*End of document.*
