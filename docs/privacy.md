# Privacy posture — Grove V1

**Last updated:** 2026-07-21
**Scope:** What leaves the box, who receives it, what stays local, and how deletion works in V1. Single-author document — not a compliance template. Revisit when topology or providers change.

Reference: PRD §7.3 (privacy posture), §6.6 (query log retention), §1.6 (backups).

**A note on "the box":** Grove's AI calls (embedding, enrichment classification, Ask synthesis, intent routing) are driven by env-configured base URLs and model names (`CHAT_BASE_URL`/`EMBEDDING_BASE_URL`, `enrichment_model`/`synthesis_model`/`intent_router_model`/`embedding_model`). Whether any memory or query text leaves the box **depends on how those are set**, not on anything fixed in the code. The **current production deployment runs fully local** — see below — but the code's own defaults still point at cloud providers, so this document covers both cases.

---

## Quick answer

> **If I save a memory, who sees it?**
>
> **In the current production deployment (fully local):** nobody but the box itself. Embedding, enrichment classification, Ask synthesis, and intent routing all run on the same self-hosted Fedora machine (AMD Radeon 6900 XT, Ollama) that holds the database — see `docs/local-inference-setup-fedora.md`. No memory text or query text leaves the box for any of those calls. The only thing that leaves the box at all is the nightly encrypted backup archive.
>
> **If Grove is instead configured against the cloud defaults baked into the code** (`CHAT_BASE_URL`/`EMBEDDING_BASE_URL` pointing at OpenAI/OpenRouter rather than local Ollama):
>
> 1. **OpenAI** sees the memory text once at capture, to compute an embedding vector.
> 2. **OpenRouter** (and whichever underlying provider it routes to — defaults to OpenAI `gpt-4o-mini`) sees the full memory text once per enrichment run, to classify it into specialised tables.
> 3. At query time, the memory text *also* leaves the box again to **OpenRouter** if it's retrieved as a synthesis source for a query, and the query text goes to OpenAI (embedding) and OpenRouter (intent routing, synthesis).
>
> Nobody else, in either configuration. No analytics, no telemetry, no third-party SDKs in the app.

---

## What leaves the box

Egress is **config-dependent**, not fixed. The table below is split by configuration.

### Fully-local configuration (current production deployment)

Embedding (`bge-m3`, 1024d), enrichment classification, Ask synthesis, and intent routing (all `gpt-oss-20b`) run via Ollama on the same self-hosted box that holds the database. **No memory or query text leaves the box for any of these calls.**

| Recipient | Data sent | When | Purpose | Retention |
|---|---|---|---|---|
| **Self-hosted box** (Fedora desktop, on-box Postgres + Ollama) | Everything — database rows, embeddings, inference | Continuously (hosting + inference) | Run the application entirely on owned hardware | Indefinite while the box exists |
| **Backblaze B2** | `age`-encrypted `pg_dump -Fc` archive of the whole database (ciphertext only — the box holds only the `age` public key) | Nightly | Disaster recovery | 30 days, then deleted |

### Cloud configuration (if configured against the code's defaults instead)

The code itself still defaults `enrichment_model` / `synthesis_model` / `intent_router_model` to `openai/gpt-4o-mini` via OpenRouter, and `embedding_base_url` to `None` (OpenAI). A deployment configured this way — rather than pointed at local Ollama — sends data off-box as follows:

| Recipient | Data sent | When | Purpose | Retention (per their terms) |
|---|---|---|---|---|
| **OpenAI** (`text-embedding-3-small`, or whichever model is configured) | Memory content (capture); query text (retrieval) | Per capture, per query | Generate an embedding for similarity search | API inputs not used for training per OpenAI API terms |
| **OpenRouter — synthesis** (`openai/gpt-4o-mini` by default) | Query text + retrieved memory excerpts | Per query that triggers synthesis | Compose RAG answer | Varies by underlying provider; OpenRouter passes through provider terms |
| **OpenRouter — intent router** (`openai/gpt-4o-mini` by default) | Query text only | Per query | Classify intent before specialised-table retrieval | Same as synthesis |
| **OpenRouter — enrichment classifier** (`openai/gpt-4o-mini` by default) | Full memory content | Per memory, during hourly enrichment run | Classify into decisions / people / appointments | Same as synthesis |

### Per-service detail (cloud configuration only)

#### OpenAI — embeddings only

- Model: `text-embedding-3-small` (1536 dimensions) is the code default; any OpenAI-compatible embedding model can be configured.
- Receives: full memory content at capture time; full query text at retrieval time.
- Logged: token counts (in `query_logs`); the request body itself is not retained server-side beyond the API call.
- OpenAI's API terms (as of writing) state API inputs are not used to train their models.

#### OpenRouter — three routes, all default to `openai/gpt-4o-mini`

OpenRouter is a routing layer. Each route is configurable independently via env vars (`enrichment_model`, `synthesis_model`, `intent_router_model`). Default routes go to OpenAI through OpenRouter; switching to a different upstream changes the privacy story for that route.

- **Synthesis**: receives the user's query text *and* the body text of the top retrieved memories (the chunks shown as sources in the Ask tab).
- **Intent router**: receives the user's query text only — no memory content.
- **Enrichment classifier**: receives full memory content during the hourly enrichment cron. Confidence ≥ 0.7 results are written to specialised tables.

Spend is capped at `OPENROUTER_MONTHLY_CAP_USD` (default 20). At cap, synthesis degrades to ranked-snippets-only (no LLM call) and enrichment no-ops for the rest of the month — both reduce egress when hit.

### Self-hosted box detail (applies regardless of AI-provider configuration)

- A dedicated Fedora desktop (AMD Radeon 6900 XT, not dual-boot) running Docker Compose with the Postgres + app containers, and — in the fully-local configuration — Ollama serving inference. See `docs/local-inference-setup-fedora.md`.
- **Disk encryption at rest: unknown.** This is physical hardware at the operator's home; whether the disk is encrypted at rest has not been configured or verified. Treat the disk as unencrypted at rest until verified. *V2 follow-up: confirm or configure disk encryption.*
- TLS to the app is via a Tailscale-issued Let's Encrypt cert in front of Apache, which reverse-proxies to FastAPI. MacBook and iPhone clients reach the box over Tailscale.

#### Backup target

- Mechanism: nightly `pg_dump -Fc`, verified non-empty and structurally valid, then encrypted with [`age`](https://github.com/FiloSottile/age) to a recipient public key (the box holds only the public key — the private key lives off-box with the operator) before being uploaded to Backblaze B2 via `rclone`. 30-day retention.
- Because encryption happens before upload, Backblaze B2 only ever holds ciphertext — a compromised or subpoenaed backup target cannot read the archive without the off-box private key.
- **Status:** the backup pipeline (`ops/scripts/backup-postgres.sh`) is authored and lint-checked but, as of this writing, unverified end-to-end against a live production stack — see `ops/RUNBOOK.md` for the restore-drill status.

---

## What does NOT leave the box

- **iOS draft captures before Save.** Recording, transcription edits, filler-word cleanup, language detection, and the character/token chip all run locally on the phone. Nothing is uploaded until the user taps Save.
- **The local SwiftData store on the phone.** The phone's queue of pending and recently-saved captures persists in SwiftData under the app sandbox. iCloud sync is not enabled for this store.
- **Action Button flow.** Triggering the Action Button opens the capture screen locally; no network call happens until Save.
- **Intent routing decisions and retrieval ranking.** Once specialised tables exist on the box, the ranking and filtering of *which* memories to retrieve happens locally in Postgres. Only the resulting top-K excerpts plus the query text are sent to the synthesis route.
- **Operational metadata** — request logs, rate-limit buckets, spend counters — all stay on the self-hosted box.
- **Third-party analytics, crash reporters, SDKs**: none. The iOS app has no Firebase / Sentry / TelemetryDeck / etc. The server has no analytics middleware.

### Out of our control: iOS system dictation

The iOS app uses the system keyboard's microphone button for transcription. Whether dictation runs on-device or is sent to Apple's servers depends on the user's iOS settings (Settings → General → Keyboard → Enable Dictation; on supported devices, "On-Device Mode" is selectable). We do not call `SFSpeechRecognizer` directly and cannot force on-device mode from the app.

---

## Query logs

Query logs are owned data, stored at the same trust level as memory content (PRD §6.6, §7.3). Each row captures:

- The query text
- The query embedding (1024d with `bge-m3` in the fully-local configuration; 1536d if configured against OpenAI `text-embedding-3-small`)
- The list of memory UUIDs returned (`returned_memory_ids`, `ARRAY(UUID)`, **no FK constraint by design**)
- Token counts and timing

Query logs are included in the nightly backup and the 30-day retention applies the same way as for memories.

---

## Deletion behaviour

`DELETE /v1/memories/{id}` (called from the iOS memory-detail view):

**Cascades** (via SQLAlchemy `delete-orphan` + DB-level `ON DELETE CASCADE`):

- `memory_chunks` (the embedded segments)
- `decisions`, `people_interactions`, `appointments` (specialised enrichment rows)

**Does NOT cascade** (intentional, per PRD §6.6):

- `query_logs.returned_memory_ids` — the deleted memory's UUID remains in any prior query log's array. The audit trail of *which UUIDs were returned for past queries* survives memory deletion, but those UUIDs no longer resolve to anything. Query text and embedding are untouched.

**Backups:** the nightly `pg_dump` is a point-in-time snapshot. A deleted memory is absent from subsequent snapshots, but earlier snapshots containing the row remain on the backup target until they age out (≤ 30 days). There is no proactive deletion from existing backups.

**Third-party caches:** if configured against cloud providers, OpenAI / OpenRouter may retain inference logs per their own retention windows. We do not issue deletion requests to upstream providers. For V1, the project accepts this — the alternative (delete-on-the-providers protocol) is out of scope. Not applicable in the fully-local configuration, where no third party ever sees the content.

---

## Known gaps (V2 candidates)

These are honest gaps, not blockers for V1 personal use:

- Self-hosted box disk encryption at rest: unverified.
- Backup encryption: `age` client-side encryption before upload is implemented (see `ops/RUNBOOK.md`), but as of this writing has not been exercised end-to-end against a live production stack (no restore drill performed yet).
- Provider-side deletion: no mechanism to ask OpenAI / OpenRouter to purge inference logs for a deleted memory, applicable only when configured against cloud providers.
- Multi-tenant readiness: this entire document assumes a single operator-user. The posture would need to change materially before accepting another person's data on the same box (see `docs/multi-tenant-scaling-exploration.md`).
