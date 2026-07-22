# Fully-local inference on Fedora (AMD gfx1030)

Run **Grove** with **no external LLM APIs**: embeddings, enrichment, synthesis,
and intent routing all served locally by Ollama on a Radeon 6900 XT (gfx1030),
which is on Ollama's hardcoded ROCm GPU list — native ROCm, no `HSA_OVERRIDE`,
no Vulkan fallback. Target box: Fedora, 6900 XT (16 GB VRAM), 64 GB RAM,
dedicated (not dual-boot).

Expected Ask latency: **~2–5 s** with `gpt-oss-20b` fully in VRAM. Marginal
cost: electricity + backups (a few USD/mo).

> The provider base URLs and the 1024-d `bge-m3` embedding default are already
> in the codebase (shipped in #518/#519) — there are **no code edits** to make.
> This guide is host setup + configuration only.

---

## 1. ROCm

```bash
sudo dnf install -y rocm-hip rocminfo rocm-smi
sudo usermod -aG video,render "$USER"   # GPU device access; log out/in after
rocminfo | grep -i gfx                    # expect: gfx1030
```

If `rocminfo` doesn't show `gfx1030`, stop here — nothing below will use the
GPU. Kernel just bumped? ROCm can lag a new Fedora kernel a week or two; boot
the prior kernel from GRUB until it catches up.

## 2. Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh   # installs + enables ollama.service
sudo systemctl enable --now ollama
journalctl -u ollama --no-pager | grep -i rocm  # confirm it picked the GPU, not CPU
```

Pull the models:

```bash
ollama pull gpt-oss-20b   # chat: enrichment + synthesis + intent (~12 GB Q4)
ollama pull bge-m3         # embeddings, 1024-d (~1 GB; CPU or GPU, doesn't matter)
```

Smoke-test throughput before wiring anything up:

```bash
ollama run gpt-oss-20b "Summarize: the quick brown fox." --verbose
# check eval rate (tok/s) in the trailing stats — want 40+ for snappy Asks
```

Ollama exposes an **OpenAI-compatible** API at `http://localhost:11434/v1`.
That's the whole integration surface.

## 3. Container reaches host Ollama

Ollama runs on the host; the `app` container must reach it. On Linux this
requires a `host-gateway` alias under the `app` service in
`docker-compose.yml`:

```yaml
  app:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

> **Note:** at time of writing this is not yet baked into the committed
> `docker-compose.yml` (tracked in #535) — confirm it's present before first
> boot, or add it. On Docker Desktop (macOS) the alias resolves automatically;
> on Linux it is required or every LLM/embedding call from the container fails.

## 4. Configuration (`production.env`)

Grove reads its config from an env file (the one `docker compose --env-file`
and the systemd units point at; keep it outside the repo, e.g.
`~/.config/grove/production.env`). For fully-local inference:

```dotenv
# Local inference — nothing leaves the box
CHAT_BASE_URL=http://host.docker.internal:11434/v1
EMBEDDING_BASE_URL=http://host.docker.internal:11434/v1
ENRICHMENT_MODEL=gpt-oss-20b
SYNTHESIS_MODEL=gpt-oss-20b
INTENT_ROUTER_MODEL=gpt-oss-20b
EMBEDDING_MODEL=bge-m3           # matches the repo default; 1024-d
OPENAI_API_KEY=ollama            # ignored by Ollama; just can't be empty
OPENROUTER_API_KEY=ollama        # same

# Required regardless of inference backend
DATABASE_URL=postgresql+asyncpg://grove:<password>@postgres:5432/grove
# ... bearer token, Tailscale hostname, etc. — see example.env
```

The repo already defaults `embedding_model` to `bge-m3` and `EMBEDDING_DIM` to
`1024`; the chat models default to a cloud model, so the `*_MODEL` overrides
above are what flip chat to local. `CHAT_BASE_URL` tolerates a trailing slash.

**No re-embed on a fresh deploy.** A new box starts with an empty database and
embeds everything with `bge-m3` from the first capture — nothing to migrate.
(Re-embedding is only a concern if you *later* switch embedders while the corpus
already holds vectors from a different model; the vector space is not comparable
across models. No re-embed helper exists yet — write one before any future
embedder switch.)

## 5. Bring the stack up

Migrations apply automatically on container start (`entrypoint.sh` runs
`alembic upgrade head`, idempotent and fail-fast — #519), so a fresh box comes
up schema-complete with no manual step.

```bash
cd /opt/grove   # wherever the repo is deployed; match WorkingDirectory in the units
docker compose --env-file ~/.config/grove/production.env up -d --build
curl -s localhost:8000/readyz && echo OK
```

## 6. Enrichment timer

The hourly enrichment worker runs as a systemd timer, ordered after both Docker
and Ollama. The units live at `ops/systemd/grove-enrichment.{service,timer}`;
install and enable them per **`ops/RUNBOOK.md` → "Enrichment cron (systemd
timer)"** (create the `grove` system user, `enable --now ollama`, copy the
units, `enable --now grove-enrichment.timer`).

## 7. Networking (Tailscale)

Tailscale is private ingress for your other devices; with fully-local inference
the only egress is the nightly backup.

```bash
sudo dnf install -y tailscale && sudo systemctl enable --now tailscaled
sudo tailscale up
# firewall: allow in only on the tailscale0 interface; allow out only for backups
```

## 8. Backups

age-encrypted `pg_dump` to Backblaze B2, nightly, via the committed script and
timer (`ops/scripts/backup-postgres.sh`, `ops/systemd/grove-backup.{service,timer}`
— #526). Full setup (off-box `age` keypair, `rclone` B2 config, retention, and
the **restore drill**) is in **`ops/RUNBOOK.md` → "Nightly backup" / "Restore
drill"**. Do one restore drill before trusting it.

---

## Validation checklist

- [ ] `rocminfo` shows `gfx1030`
- [ ] `journalctl -u ollama` shows ROCm/GPU, not CPU fallback
- [ ] `ollama run gpt-oss-20b --verbose` eval rate ≥ 40 tok/s
- [ ] `extra_hosts` host-gateway alias present on the `app` service
- [ ] `docker compose ... up -d` and `/readyz` returns OK (migrations auto-applied)
- [ ] a real Ask returns in a few seconds and network egress is zero during it
      (`sudo ss -tp` shows no outbound to openai/openrouter)
- [ ] enrichment timer installed and firing hourly
- [ ] backup written to B2 and restored once
```
