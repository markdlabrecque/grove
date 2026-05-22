# Privacy posture — Grove V1

**Last updated:** 2026-05-15
**Scope:** What leaves the box, who receives it, what stays local, and how deletion works in V1. Single-author document — not a compliance template. Revisit when topology or providers change.

Reference: PRD §7.3 (privacy posture), §6.6 (query log retention), §1.6 (backups).

---

## Quick answer

> **If I save a memory, who sees it?**
>
> 1. **OpenAI** sees the memory text once at capture, to compute an embedding vector.
> 2. **OpenRouter** (and whichever underlying provider it routes to — defaults to OpenAI `gpt-4o-mini`) sees the full memory text once per enrichment run, to classify it into specialised tables.
> 3. **Hetzner** stores the database row on a CX22 instance.
> 4. Nightly the row gets included in a `pg_dump` archive uploaded to a Hetzner Storage Box or Backblaze B2 bucket.
>
> At query time, the memory text *also* leaves the box again to **OpenRouter** if it's retrieved as a synthesis source for a query.
>
> Nobody else. No analytics, no telemetry, no third-party SDKs in the app.

---

## What leaves the box

| Recipient | Data sent | When | Purpose | Retention (per their terms) |
|---|---|---|---|---|
| **OpenAI** (`text-embedding-3-small`) | Memory content (capture); query text (retrieval) | Per capture, per query | Generate 1536d embedding for similarity search | API inputs not used for training per OpenAI API terms |
| **OpenRouter — synthesis** (`openai/gpt-4o-mini` by default) | Query text + retrieved memory excerpts | Per query that triggers synthesis | Compose RAG answer | Varies by underlying provider; OpenRouter passes through provider terms |
| **OpenRouter — intent router** (`openai/gpt-4o-mini` by default) | Query text only | Per query | Classify intent before specialised-table retrieval | Same as synthesis |
| **OpenRouter — enrichment classifier** (`openai/gpt-4o-mini` by default) | Full memory content | Per memory, during hourly enrichment run | Classify into decisions / people / appointments | Same as synthesis |
| **Hetzner** (CX22 VPS) | Postgres database (memories, chunks, specialised tables, query logs) | Continuously (hosting) | Run the application | Indefinite while the instance exists |
| **Backup target** (Hetzner Storage Box *or* Backblaze B2 — not yet selected for production) | Compressed `pg_dump -Fc` of the whole database | Nightly | Disaster recovery | 30 days, then deleted by host cron |

### Per-service detail

#### OpenAI — embeddings only

- Model: `text-embedding-3-small` (1536 dimensions).
- Receives: full memory content at capture time; full query text at retrieval time.
- Logged: token counts (in `query_logs`); the request body itself is not retained server-side beyond the API call.
- OpenAI's API terms (as of writing) state API inputs are not used to train their models.

#### OpenRouter — three routes, all default to `openai/gpt-4o-mini`

OpenRouter is a routing layer. Each route is configurable independently via env vars (`enrichment_model`, `synthesis_model`, `intent_router_model`). Default routes go to OpenAI through OpenRouter; switching to a different upstream changes the privacy story for that route.

- **Synthesis**: receives the user's query text *and* the body text of the top retrieved memories (the chunks shown as sources in the Ask tab).
- **Intent router**: receives the user's query text only — no memory content.
- **Enrichment classifier**: receives full memory content during the hourly enrichment cron. Confidence ≥ 0.7 results are written to specialised tables.

Spend is capped at `OPENROUTER_MONTHLY_CAP_USD` (default 20). At cap, synthesis degrades to ranked-snippets-only (no LLM call) and enrichment no-ops for the rest of the month — both reduce egress when hit.

#### Hetzner — VPS hosting

- Hetzner CX22 (2 vCPU, 4 GB RAM) running Docker Compose with the Postgres + app containers.
- **Disk encryption at rest: unknown.** The default Hetzner Cloud volume is not configured for LUKS in this project, and we have not verified whether Hetzner provides volume-level encryption at the infrastructure layer. Treat the disk as unencrypted at rest until verified. *V2 follow-up: confirm or configure LUKS.*
- TLS to the app is via a Tailscale-issued Let's Encrypt cert in front of Apache, which reverse-proxies to FastAPI.

#### Backup target

- Mechanism: nightly `pg_dump -Fc` written to a mount point (`/mnt/storagebox/...` or rclone-mounted B2 bucket). 30-day retention via `find ... -mtime +30 -delete`.
- **Encryption: the dump file is plain (Postgres custom format, not encrypted). Transport is TLS to the storage provider. There is no client-side encryption (gpg/age) before upload.** Provider-side server encryption depends on the destination (Storage Box / B2) — we do not hold a customer-managed key. *V2 follow-up: client-side encrypt with age before upload so the backup target sees only ciphertext.*
- The production backup target has not yet been deployed; both Hetzner Storage Box and Backblaze B2 are documented as options in `ops/RUNBOOK.md` and the operator picks one at deploy time.

---

## What does NOT leave the box

- **iOS draft captures before Save.** Recording, transcription edits, filler-word cleanup, language detection, and the character/token chip all run locally on the phone. Nothing is uploaded until the user taps Save.
- **The local SwiftData store on the phone.** The phone's queue of pending and recently-saved captures persists in SwiftData under the app sandbox. iCloud sync is not enabled for this store.
- **Action Button flow.** Triggering the Action Button opens the capture screen locally; no network call happens until Save.
- **Intent routing decisions and retrieval ranking.** Once specialised tables exist on the box, the ranking and filtering of *which* memories to retrieve happens locally in Postgres. Only the resulting top-K excerpts plus the query text are sent to the synthesis route.
- **Operational metadata** — request logs, rate-limit buckets, spend counters — all stay on the Hetzner box.
- **Third-party analytics, crash reporters, SDKs**: none. The iOS app has no Firebase / Sentry / TelemetryDeck / etc. The server has no analytics middleware.

### Out of our control: iOS system dictation

The iOS app uses the system keyboard's microphone button for transcription. Whether dictation runs on-device or is sent to Apple's servers depends on the user's iOS settings (Settings → General → Keyboard → Enable Dictation; on supported devices, "On-Device Mode" is selectable). We do not call `SFSpeechRecognizer` directly and cannot force on-device mode from the app.

---

## Query logs

Query logs are owned data, stored at the same trust level as memory content (PRD §6.6, §7.3). Each row captures:

- The query text
- The query embedding (1536d)
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

**Third-party caches:** OpenAI / OpenRouter may retain inference logs per their own retention windows. We do not issue deletion requests to upstream providers. For V1, the project accepts this — the alternative (delete-on-the-providers protocol) is out of scope.

---

## Known gaps (V2 candidates)

These are honest gaps, not blockers for V1 personal use:

- Hetzner disk encryption at rest: unverified.
- Backup encryption: no client-side encryption; relies on transport TLS and provider posture.
- Provider-side deletion: no mechanism to ask OpenAI / OpenRouter to purge inference logs for a deleted memory.
- Multi-tenant readiness: this entire document assumes a single operator-user. The posture would need to change materially before accepting another person's data on the same box (see `docs/multi-tenant-scaling-exploration.md`).
