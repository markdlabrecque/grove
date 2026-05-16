# Grove — Multi-Tenant Scaling Exploration

**Status:** Exploratory — no tickets, no implementation. A picture of what it would take to evolve Grove from a single-user personal system into a multi-tenant product, sketched at three user-count milestones (100 / 1,000 / 10,000).

**Date:** 2026-05-10
**Branch:** `worktree-multitenant-exploration`

---

## 1. Where we are today (the baseline)

Grove is intentionally single-tenant in V1. Every architectural decision — auth, schema, deployment, enrichment cadence — assumes exactly one user. That is not an oversight; the PRD lists "no multi-user" as an explicit non-goal. This is fine: it means there is no legacy multi-tenancy code to undo, but it also means there is essentially nothing to build on. Multi-tenancy is a re-foundation, not a feature.

### Today's stack at a glance

| Layer | Implementation | Multi-tenant readiness |
|---|---|---|
| **iOS client** | SwiftUI + SwiftData, URLSession background uploads, on-device Speech transcription. Auth = a single `BEARER_TOKEN` baked into `.xcconfig` at build time. | None. One build = one user. No login flow. |
| **API** | FastAPI 0.115, async SQLAlchemy 2.x, uvicorn. Auth = constant-time compare against the env var `BEARER_TOKEN`. | None. No user concept exists. |
| **Database** | Postgres 16 + pgvector (HNSW, 1536-dim). 10 tables, all immutable-append. **No `user_id` column anywhere.** | None. Tenancy column missing on every table. |
| **Enrichment** | Hourly batch worker (planned). Reads all unenriched memories globally, classifies, writes to specialized tables (`decisions`, `people_interactions`, `tasks`, `appointments`). | None. Single global queue. |
| **LLM/embeddings** | OpenAI `text-embedding-3-small` for vectors. OpenRouter (cheap Haiku-class) planned for synthesis and classification. Direct SDK calls — no gateway, no per-tenant accounting. | None. No spend caps, no metering. |
| **Hosting** | Hetzner CX22 (2 vCPU, 4 GB RAM), Docker Compose, Apache httpd reverse proxy, Tailscale-issued LE certs. Nightly `pg_dump` to Storage Box / B2. | Adequate for one user; trivial for ~100. |
| **Cost** | Target $5–10/mo, ceiling $20/mo. Dominated by hosting today; LLM spend negligible at personal volume. | Linear in users once usage is real. |

### The single-tenant assumptions baked in

These are the things that *must* change before you can sell access to a second person:

1. **One bearer token.** Identical token on every iOS install. There is no notion of "who" is calling.
2. **No `user_id` column on any table.** Every query implicitly scopes to "everything". Adding tenancy is a migration that touches *every* table.
3. **No access control on writes/reads.** `DELETE /v1/memories/{id}` would happily delete *anyone's* memory if there were anyone else's memories to delete.
4. **Global enrichment batch.** One cron, one queue, no fairness. A single chatty user starves the rest.
5. **Shared pgvector index.** Embeddings co-mingled — needs either a `user_id` predicate on every ANN query (and a composite index) or per-tenant indexes / partitioned tables.
6. **Hardcoded DB URL.** No routing layer; can't shard or per-tenant-shard without surgery.
7. **No rate limiting, no quota, no billing surface.** Even if you fixed auth, you couldn't bound a user's cost.
8. **Secrets shipped to the client.** The bearer token lives in `.xcconfig` and ends up in `Info.plist` in the app bundle. Any per-user equivalent needs Keychain + a real login flow.

### What *is* forward-compatible

Not nothing. A few V1 decisions help:

- **`enrichment_version` and `embedding_model` are stamped per row** — so you can re-enrich or re-embed selectively when models or providers change. This matters at scale because the embedding provider swap is existential at 10K users.
- **Specialized tables cascade-delete from `memories`** — adding `user_id` to `memories` and propagating via FKs is mechanical.
- **Immutable-append** — no in-place edits means no concurrent-write contention story to design around.
- **Structured logs (structlog JSON)** — usable for per-tenant cost attribution as soon as a `user_id` exists in the log context.

---

## 2. Milestone: ~100 users

**Mental model:** "A handful of friends, an early beta, or one small team." Load is trivial. The work here is almost entirely *architectural plumbing* to introduce the concept of a user — the infrastructure barely cares.

### What must change

**Auth & identity (the big one).**
- Introduce a `users` table (id, email, created_at, status, plan).
- Replace bearer-token middleware with a real identity provider. At 100 users, **don't build this yourself.** Pick one:
  - **Apple Sign-In** — natural fit, iOS-first, free, gives you a stable opaque user id.
  - **Clerk / Auth0 / Supabase Auth** — managed, JWT-based, gives you password reset / MFA for free.
- iOS gets a login screen. Token lives in Keychain (the V2 plan already anticipates this — `// TODO(auth):` markers exist).
- The xcconfig `BEARER_TOKEN` goes away; the app fetches a per-user JWT and refreshes it.

**Schema migration.**
- Add `user_id UUID NOT NULL REFERENCES users(id)` to: `memories`, `memory_chunks`, `query_logs`, `enrichment_state`, `decisions`, `people_interactions`, `tasks`, `appointments`.
- Composite indexes: every existing index needs to be `(user_id, ...)`. This includes the HNSW vector indexes — pgvector supports filtered ANN, but filtered HNSW with low selectivity is painful, so a composite B-tree on `(user_id, created_at)` plus a per-user pre-filter via partial indexes or partitioning is the realistic shape.
- Consider Postgres **Row-Level Security (RLS)** policies as a belt-and-braces guard. RLS at 100 users is essentially free and prevents a class of "forgot the WHERE clause" bugs that *will* happen otherwise.

**Cost & quotas.**
- Per-user spend cap (daily $ ceiling on embeddings + synthesis), enforced before the API call, logged when hit.
- This is the moment to introduce a thin LLM gateway in the server (one async function the rest of the code calls) so that metering and provider swaps land in one place.

**Enrichment.**
- Worker becomes per-user. Simplest viable: one job per `(user_id, hour)` slot in a queue table; worker pops the oldest. APScheduler or a tiny `asyncio` loop is enough — no Celery yet.

**Operational.**
- Per-user log context (`structlog.bind(user_id=...)`).
- Backup retention review: 30 days of full DB dumps is fine for personal use, less fine when one row in there is someone else's diary. Encrypt backups at rest; document the restore-of-one-user procedure (you will eventually be asked).
- **Privacy posture changes legally.** You are now a data processor. Privacy policy, deletion-on-request endpoint, ToS. Not optional in any jurisdiction worth shipping in.

### Infrastructure at 100 users

Honestly? **The Hetzner CX22 still handles it.** A hundred users at personal-scale capture volume is maybe 10K memories/month total — well within a single small Postgres. The work is almost entirely *code and policy*, not infrastructure.

### Rough cost shape

- Hosting: unchanged (~$6/mo).
- Embeddings: ~$1–5/mo total (100× single-user budget).
- Synthesis: ~$50–200/mo total (the cost is per-query, and 100 active users each running a few queries a day adds up faster than capture).
- **Operational time**: this is the real cost. Auth, RLS, schema migration, login UX in iOS — call it a 4–6 week build for one engineer.

### Risks at this scale

- **Schema migration without downtime is harder than the migration itself.** With 100 users you can probably take a maintenance window. Don't pretend you can't.
- **Apple Sign-In + family-share edge cases.** Worth deciding early whether one Apple ID = one Grove account, or whether you allow rebinding.
- **The single bearer token still exists in old app builds.** Plan a hard cutover, not a soft migration, or you'll support two auth modes forever.

---

## 3. Milestone: ~1,000 users

**Mental model:** "A real product with paying customers." Load is still small in absolute terms, but you now have *availability* expectations, *cost* attention, and *abuse* to think about.

### What must change beyond the 100-user state

**Database is still a single Postgres — but with care.**
- 1,000 users × maybe 100 memories/user/month = 100K memories/month, 1.2M/year. A well-indexed Postgres 16 on a 4-core / 16 GB VM does this in its sleep.
- **pgvector is the thing to watch.** HNSW index build time and memory grow with row count. At ~1M vectors you're still fine on commodity hardware; at ~5M you start considering IVFFlat with per-tenant lists, or moving vectors out.
- Read replica for analytics / admin dashboards so you're not running ad-hoc queries against the primary.
- Connection pooling via **PgBouncer** (transaction-mode) becomes mandatory — FastAPI's async pool doesn't substitute for it under burst load.

**The LLM gateway gets real.**
- Centralized provider abstraction (OpenAI, OpenRouter, Anthropic direct, self-hosted) so you can A/B model swaps for cost.
- Per-user, per-day, per-month spend ledger. This is the single highest-leverage piece of code in the product at this scale — you make or lose your margin here.
- **Streaming responses** for synthesis become important UX-wise; the gateway needs to support it.

**Background work moves out of the API process.**
- A real queue (Redis + RQ, or Postgres-as-queue via `SKIP LOCKED`, or hosted like Inngest) for enrichment, embedding, and any "do this later" path.
- Per-user fairness in the queue (round-robin across users rather than FIFO) so one heavy user doesn't starve the rest.

**iOS gets multi-device.**
- A user has an iPhone *and* an iPad. SwiftData sync state is now per-(user, device). This is mostly client-side work but the server needs to handle "same user, multiple `client_id` streams" cleanly (it already does via the `client_id` UNIQUE, but you want to think about it).

**Abuse & quotas.**
- Rate limits per user (e.g., 100 captures/hour, 50 queries/hour). Nginx/Apache-level for crude DoS, application-level for fairness.
- Embedding/synthesis spend caps with hard cutoff + email notification.
- Captcha or phone verification on signup to keep cost-attackers out — a free tier of "unlimited LLM-backed search" is irresistible to abusers.

**Observability.**
- Per-tenant metrics: captures/day, queries/day, $/day, p95 query latency. Without this you cannot price the product or spot a user about to bankrupt you.
- Error budget / SLO. At this scale customers expect 99.9% — that's ~43 minutes of downtime per month, which is *less than one bad deploy*. Implies blue/green or at least zero-downtime migrations.

### Infrastructure at 1,000 users

- **App tier:** 2–3 small VMs behind a load balancer (Hetzner LB or Cloudflare in front), or move to a managed runtime (Fly.io, Railway, Render) to stop hand-rolling Compose.
- **DB tier:** Single primary (8 vCPU / 32 GB) + one read replica. Managed Postgres is a fair call here — Crunchy Bridge, Neon, or Supabase — to offload PITR, backups, and failover. Hetzner managed Postgres also exists and is cheap.
- **Vector tier:** Still pgvector, still co-located. Don't split it out yet.
- **Cache:** Redis for sessions, rate limits, queue.
- **Object storage:** B2 or R2, used for backups and (if you eventually accept attachments) raw blobs.

### Rough cost shape

- Hosting: $100–300/mo (VMs + managed Postgres + Redis + LB).
- Embeddings: $50–200/mo.
- Synthesis: $500–2,000/mo — **this is the line item that decides whether you have a business.** Pricing the product means understanding p95 queries/user/day × tokens/query × $/token, and pricing above that with margin.
- **Per-user gross cost:** roughly $0.50–$2.50/user/month all-in. Implies a price point north of $5/mo to have meaningful margin.

### Risks at this scale

- **The first cost-attacker.** Someone signs up, scripts 10K queries/hour. Without quotas live before you have 1,000 users, you find out the expensive way.
- **Embedding model drift.** OpenAI deprecates `text-embedding-3-small` (or a successor comes out that's 2× better at the same price). With `embedding_model` per row, you *can* re-embed selectively — but you need the orchestration to do so without melting the DB. Build that capability before you need it.
- **Support load.** 1,000 users with personal data generates real support volume. You need a deletion-on-request workflow, an export-my-data endpoint, and at least one human checking email.

---

## 4. Milestone: ~10,000 users

**Mental model:** "Scale where individual user data sets matter and the LLM bill is the company's biggest expense." This is where the V1 architecture stops being recognizable.

### What must change beyond the 1,000-user state

**Data tier splits.**
- **Vectors leave Postgres.** At ~10M–100M vectors, pgvector with HNSW is no longer the obvious right answer. Options, in order of "least surprising":
  - **pgvector with partitioning + IVFFlat per-tenant** — still Postgres, still one operational story. Works further than people think.
  - **Qdrant or Weaviate self-hosted** — purpose-built, namespaced per-tenant, scales horizontally. Adds a service to operate.
  - **Pinecone / Turbopuffer** — managed, expensive, but the right call if vector ops are the team's bottleneck.
  - The choice is driven by *p95 query latency* and *re-index cost*, not raw scale. Benchmark before deciding.
- **Postgres shards.** Either by `user_id` hash (Citus, or roll your own with a routing layer) or by region. At 10K users you might still get away with one big primary, but you definitely need read replicas, async standbys for DR, and probably PITR via WAL-G.
- **Cold/warm split.** Memories older than N months that nobody queries get moved to a cheaper store (S3 + Parquet, queryable on demand). Most users only query the last 90 days.

**Tenancy model decision becomes load-bearing.**
- **Pool model (everyone in one DB, `user_id` everywhere)** — cheapest, scales further than it should, RLS-or-bust for safety.
- **Silo model (one DB per tenant)** — natural fit for enterprise/team plans, terrible operational story for 10K of them.
- **Hybrid (pool for free/individual tier, silo for enterprise)** — most likely answer if you sell to companies. Pick this *before* you have 10K users, because retrofitting is brutal.

**LLM cost is the company.**
- Self-hosted embedding model on GPUs is now viable: at 10K users × moderate capture, you're embedding 1M–10M chunks/month. OpenAI charges ~$0.02/M tokens — call it $20–200/mo just for embeddings, still cheap. **Don't self-host yet — stay with the API.**
- Synthesis is the spend. At 10K users × a few queries/day × ~2K tokens/query, you're at hundreds of millions of tokens/month. Even at Haiku/4o-mini prices ($0.15–$0.60/M input, $0.60–$2.40/M output) that's $5K–$30K/mo. Levers:
  - **Aggressive caching** of synthesis on identical query embeddings.
  - **Cheaper retrieval-only mode** for queries that don't need synthesis.
  - **Self-hosted small model** (Llama-class on dedicated GPUs) for the common case, API for the long tail.
  - **Prompt caching** (Anthropic's prompt caching, OpenAI's variant) if any portion of the system prompt is reused — this is in your kit already per the `claude-api` skill.

**Operational maturity.**
- Multi-region deployment (latency + DR). Probably means a primary region with read replicas elsewhere, and accepting eventual consistency for non-write paths.
- On-call rotation, runbooks, incident review. Real ones.
- **SOC 2 conversation.** Enterprise customers will ask. The work starts ~12 months before you need the certificate.
- GDPR / CCPA deletion endpoints that actually delete from vectors, blobs, backups, *and* logs (within retention windows).

**Infrastructure shape.**
- App tier: ~10–20 instances on a managed runtime (Fly, Kubernetes, ECS — pick your poison).
- DB tier: sharded or partitioned primary + replicas + PITR + a real DBA on call.
- Vector tier: dedicated service.
- Background workers: separate fleet, autoscaling on queue depth.
- Cache + queue: managed Redis / ElastiCache.
- Object storage: S3 or R2 with lifecycle policies.
- LLM gateway: now its own service with rate limiting, caching, fallback providers, and per-tenant spend ledgers as the system of record for billing.

### Rough cost shape

- Hosting + DB + vector + cache + storage: $3K–$10K/mo depending on choices.
- Embeddings: $200–$2K/mo.
- Synthesis: $5K–$30K/mo (dominant line item — see above).
- Salaries are by far the biggest cost line at this point. Engineering team of 3–5 people minimum.
- **Per-user gross cost (infra + LLM only):** ~$0.80–$4/user/mo. Pricing implication: a $9.99/mo individual tier is viable; anything cheaper requires real cost optimization (caching, self-hosted models).

### Risks at this scale

- **Vector store migration**, if needed, is *the* highest-risk operation you will ever do. Per-row `embedding_model` versioning helps, but you're still moving billions of bytes with a correctness invariant. Plan it as a quarter, not a sprint.
- **One bad tenant.** A power user with 10M memories breaks every assumption about query latency, index size, and cost. Have a "VIP tier" or hard caps from day one.
- **Compliance debt.** Anything you skipped at 1,000 users (encryption at rest specifics, key rotation, deletion guarantees, audit logs) is now a *blocker* for enterprise deals.
- **LLM provider risk.** A single provider going down or changing pricing 2× kills the business. The LLM gateway abstraction you built at 1,000 users earns its keep here.

---

## 5. Architectural shape — what survives, what doesn't

Working backwards from the 10K-user picture to what the V1 codebase already does well:

| V1 decision | Survives to 10K? | Why |
|---|---|---|
| FastAPI + async SQLAlchemy | ✅ | Scales horizontally; standard pattern. |
| Postgres as primary store | ✅ | Even at 10K, Postgres is still the spine. |
| pgvector as vector store | ⚠️ Maybe | Could survive if partitioned; likely replaced. |
| `embedding_model` per row | ✅ | Critical at scale; can't change without it. |
| `enrichment_version` per row | ✅ | Same reason. |
| Specialized tables (`decisions`, `people_interactions`, ...) | ⚠️ Maybe | PRD already flags these as prototypes. Real classification at scale may collapse into one polymorphic `extractions` table. |
| Single bearer token | ❌ | Dies at 100 users. |
| No `user_id` column | ❌ | Dies at 100 users. |
| Direct OpenAI SDK calls | ❌ | Dies at 1,000 users — replaced by LLM gateway. |
| Hetzner CX22 + Compose | ❌ | Dies at 1,000 users — replaced by managed runtime or LB'd VMs. |
| Hourly global enrichment cron | ❌ | Dies at 100 users — replaced by per-user queued jobs. |
| iOS xcconfig token | ❌ | Dies at 100 users — Keychain + login flow (V2 plan already anticipates this). |
| Immutable-append data model | ✅ | Gift that keeps giving. |
| Structured JSON logs | ✅ | Just needs `user_id` bound into context. |

The honest summary: **the data model is mostly forward-compatible; the auth, deployment, and LLM-cost stories are not.** Those three are the multi-tenancy build.

---

## 6. The path I'd actually recommend (FWIW)

If multi-tenancy is a real direction, not just exploration:

1. **Don't do it incrementally inside V1.** V1's single-tenant assumptions are *features* for proving the personal-use thesis. Mixing in half-built multi-tenancy makes both stories worse.
2. **Decide the audience first.** "100 friends" and "10K paying customers" want different products. The vector-store and LLM-cost decisions branch dramatically on which.
3. **Earliest meaningful build is `user_id` + Apple Sign-In + RLS + per-user LLM gateway with spend caps.** That is the 100-user shape, and it's a 4–6 week build for one engineer who already knows the codebase.
4. **Don't pre-build for 10K.** Every decision at the 10K tier (vector store split, sharding, self-hosted models) is a Wrong Decision at 100. Build the 100-user shape *with the seams in the right places* — LLM gateway as a single function, RLS policies rather than ad-hoc WHERE clauses, immutable-append preserved — and the 1K and 10K migrations become tractable rather than rewrites.

The codebase is already reasonably well-positioned for that 100-user shape. The data model is clean, the schema versions models per-row, and the iOS auth migration to Keychain is already scoped as the V2 plan. The hard parts are the *new* parts — Apple Sign-In wiring, the LLM gateway, per-user enrichment fairness, RLS policies — not retrofitting the existing parts.
