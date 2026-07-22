# Grove

Grove is a personal memory system: capture short notes by voice or text,
let an AI enrichment pipeline classify them, and later ask questions over
your own corpus (semantic recall + RAG-style synthesis with citations back
to the source memory). It's built for one operator's own data — not a
multi-tenant product.

## Monorepo layout

| Path | What it is |
|---|---|
| `server/` | FastAPI + Postgres/pgvector backend — capture API, enrichment worker, retrieval/Ask pipeline. Python 3.12, SQLAlchemy 2.x async, Alembic, `structlog`. |
| `ios/` | SwiftUI client for capture (Action Button / Shortcuts, on-device dictation, background upload) and Ask. |
| `docs/` | Product and architecture docs — PRD, implementation plan, privacy posture, deployment setup. Superseded/parked material lives in `docs/archive/`. |
| `ops/` | Deployment runbook, backup scripts, Apache/Tailscale TLS config. |

## Deployment

Grove runs fully self-hosted: Postgres and the FastAPI app on a dedicated
box, reached by the MacBook and iPhone clients over Tailscale. The current
production configuration also serves **all inference locally** (embedding,
enrichment classification, Ask synthesis, intent routing) via Ollama on a
Fedora desktop with an AMD Radeon 6900 XT — no external LLM APIs, no
per-request egress. The codebase also supports pointing those same calls at
cloud providers (OpenAI / OpenRouter) instead; see
[`docs/privacy.md`](docs/privacy.md) for exactly what that configuration
choice means for data egress.

Setting up the fully-local inference stack: see
[`docs/local-inference-setup-fedora.md`](docs/local-inference-setup-fedora.md).
Setting up the rest of the stack (Docker Compose, Tailscale TLS, backups):
see [`ops/RUNBOOK.md`](ops/RUNBOOK.md).

## Key docs

- [`docs/grove-prd.md`](docs/grove-prd.md) — product requirements, the authoritative source on intent and scope.
- [`docs/grove-implementation-plan.md`](docs/grove-implementation-plan.md) — phased implementation plan, stack decisions, conventions.
- [`docs/privacy.md`](docs/privacy.md) — what leaves the box, who receives it, deletion semantics.
- [`ops/RUNBOOK.md`](ops/RUNBOOK.md) — one-time setup and routine ops.
- [`AGENTS.md`](AGENTS.md) — team/workflow conventions for humans and agents working in this repo.
