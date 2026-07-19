# Operations Runbook — Local Dev

One-time setup and routine ops for Grove running locally on macOS, served
to the iPhone over a private Tailnet with HTTPS.

In examples below, `$TAILSCALE_HOSTNAME` refers to your laptop's MagicDNS name
(e.g. `your-laptop.tailXXXXXX.ts.net`). It's set in `.env` and read by the
Makefile, the Apache container's entrypoint, and the cert scripts.

`$REPO_ROOT` is your local checkout root — e.g. `/opt/grove` on the deploy box
or `~/Projects/grove` on a dev workstation. Adjust any path that mentions it to
match your actual clone location.

## Architecture (Phase 0)

```
iPhone (on tailnet)
   │  HTTPS
   ▼
$TAILSCALE_HOSTNAME  (Tailscale MagicDNS → CGNAT IP, only routable on the tailnet)
   │
   ▼  port ${GROVE_HTTPS_PORT:-8443} published by docker-compose
┌─────────────────┐   ┌────────────┐   ┌────────────────────┐
│ apache (httpd)  │ → │ app (api)  │ → │ postgres (pgvector)│
│  TLS terminates │   │  uvicorn   │   │                    │
│  reverse proxy  │   │  :8000     │   │  :5432             │
└─────────────────┘   └────────────┘   └────────────────────┘
```

The `apache` container terminates TLS using a cert issued by Tailscale's
managed Let's Encrypt flow and reverse-proxies to the FastAPI app on the
internal compose network. The Apache config is rendered from
`ops/apache/*.template` files at container start, substituting
`@@TAILSCALE_HOSTNAME@@` with the value from `.env`.

### Why a non-default port?

The Apache container's host port defaults to **8443** rather than 443.
DDEV's reverse-proxy container claims port 443 on dev machines that run any
DDEV project; binding 443 there causes a `port is already allocated` error
at `docker compose up`. Port 8443 is a conventional alternative for
developer HTTPS that avoids this conflict.

To override — for example on a dedicated production host with no DDEV — set
`GROVE_HTTPS_PORT=443` in your `.env` before `make up`. If you update this
value on a running stack, run `make down && make up` so Docker releases and
re-binds the port. Make sure to also update the iOS app's base URL
xcconfig to match.

## One-time setup

### 1. Tailscale prerequisites

In the Tailscale admin console (https://login.tailscale.com/admin/dns):

1. Enable **MagicDNS**.
2. Enable **HTTPS Certificates**.

Find your laptop's MagicDNS name:

```
tailscale status
# look for the line ending in `.ts.net` for this device
```

Install Tailscale on the iPhone and sign in to the same tailnet.

### 2. Configure secrets

```
cp example.env .env
```

Fill in `.env`:

- `BEARER_TOKEN` — `openssl rand -hex 32`
- `POSTGRES_PASSWORD` — `openssl rand -hex 24`
- `TAILSCALE_HOSTNAME` — your laptop's MagicDNS name from step 1
- `GROVE_HTTPS_PORT` — defaults to `8443`; change to `443` only on a
  dedicated host with no DDEV (see "Why a non-default port?" above)
- `GH_TOKEN` — fine-grained PAT for the project's GitHub identity (see
  next section)
- `OPENAI_API_KEY` / `OPENROUTER_API_KEY` can stay blank until Phase 2/3

### 2a. Per-project GitHub identity (direnv)

This project uses a different GitHub account than may be globally
configured on the laptop. To keep `gh` and agent automation acting as
the right identity inside this directory, we use direnv to load
`.env` automatically.

One-time setup:

```
brew install direnv
# add to ~/.zshrc:
eval "$(direnv hook zsh)"
# reload shell, then:
direnv allow
```

Generate a fine-grained PAT at
<https://github.com/settings/tokens?type=beta>:

- Repository access: **only `markdlabrecque/grove`**
- Permissions:
  - Issues: read + write
  - Pull requests: read + write
  - Contents: read + write
  - Metadata: read
  - Workflows: read + write

Paste the token into `.env` as `GH_TOKEN=github_pat_…` (fine-grained
tokens use the `github_pat_` prefix; the older `ghp_` prefix is for
classic tokens, which we're not using). Verify:

```
gh auth status
# → Logged in to github.com account markdlabrecque (GH_TOKEN)
```

If `gh auth status` still shows the global account, your shell hasn't
re-loaded direnv — run `direnv reload` or open a new terminal in the
project. **For Claude/agent invocations to pick up the new token, the
Claude Code session must be (re)started from inside the project
directory** so it inherits the direnv-loaded environment.

### 3. Issue the dev TLS cert

```
make cert
```

Calls `sudo tailscale cert ${TAILSCALE_HOSTNAME}` and drops `<host>.crt` +
`<host>.key` into `ops/certs/`. The directory contents are gitignored.

### 4. Bring up the stack

```
make up
make health
```

`make health` curls the public health endpoints over HTTPS using the hostname
and port from `.env`. From the iPhone (on the tailnet), browsing to
`https://$TAILSCALE_HOSTNAME:${GROVE_HTTPS_PORT:-8443}/healthz` should return
JSON, no cert warning.

> **Automatic migrations on start.** The `app` container's `entrypoint.sh` runs
> `alembic upgrade head` before handing off to uvicorn (#519) — pending
> migrations are applied on every `make up` / `make rebuild`, and a failed
> migration aborts the container fail-fast rather than serving against a
> half-migrated schema. `make migrate` is still available for running it
> manually (e.g. against a stopped app container).

## CI (GitHub Actions)

The workflow at `.github/workflows/ci.yml` runs automatically on `push` to
`develop` and on all pull requests that touch `server/`, `pyproject.toml`, or
the workflow file itself. Three jobs run in parallel:

- **lint** — `ruff check` + `ruff format --check`
- **test** — `pytest server/tests/` against an ephemeral `pgvector/pgvector:pg16`
  service container (migrations applied before tests run)
- **migrations** — `alembic upgrade head && alembic downgrade base && alembic
  upgrade head` (confirms round-trip reversibility)

Python-only PRs require all three to be green before merge.

## Routine operations

Most day-to-day commands are wrapped in the repo-root `Makefile`. Run
`make help` to list them. Highlights:

| Command | Action |
|---|---|
| `make up` | Build (if needed) and start the stack |
| `make down` | Stop the stack, keep the database |
| `make nuke` | Stop AND wipe the database volume |
| `make rebuild` | Rebuild + restart only the app |
| `make logs` / `logs-app` / `logs-db` / `logs-web` | Tail logs |
| `make shell` | Bash inside the app container |
| `make psql` | psql against the dev DB |
| `make migrate` | `alembic upgrade head` |
| `make new-migration MSG="…"` | Create an autogenerated migration |
| `make test` / `make lint` / `make format` | Run pytest / ruff |
| `make cert` / `make cert-renew` | Issue / refresh the Tailscale cert |
| `make health` | Curl `/healthz` + `/readyz` over HTTPS |

The raw `docker compose` invocations still work; the Makefile is just a
convenience layer.

### Running tests on the host (faster iteration)

```
cd server
pip install -e '.[dev]'
pytest
```

## Cert renewal

Tailscale-issued certs are 90-day Let's Encrypt certs. `tailscale cert` is
idempotent — running it more often than needed is harmless and only renews
when close to expiry.

### Manual renewal

```
make cert-renew
```

Re-issues if needed and gracefully reloads the Apache container.

### Optional: weekly cron

```
crontab -e
```

Add (replace the path with your absolute project path):

```
0 9 * * 1 $REPO_ROOT/ops/scripts/renew-cert.sh >> /tmp/grove-cert-renew.log 2>&1
```

## Troubleshooting

**Apache fails to start with `TAILSCALE_HOSTNAME must be set in .env`.**
The entrypoint script couldn't find the env var. Confirm `.env` exists and
has `TAILSCALE_HOSTNAME=` filled in, then `make rebuild`.

**Apache fails to start with `SSLCertificateFile: file does not exist`.**
Run `make cert` first, then `make up`.

**iPhone can't resolve the hostname.**
Confirm Tailscale is on and `tailscale status` on the phone shows the laptop.
Toggle Tailscale off/on if MagicDNS is stale.

**`readyz` returns 500.**
Postgres isn't reachable. Check `make logs-db` and confirm
`DATABASE_URL` in `.env` matches what compose passes to the app service.

**`401 missing bearer token`.**
Expected on protected endpoints. Send `Authorization: Bearer <BEARER_TOKEN>`.
Health endpoints are unauthenticated by design so the iPhone can probe
reachability.

**`429 Too Many Requests` / `Retry-After: N`.**
The per-token rate limiter rejected the request. The client should back off for
at least `Retry-After` seconds and retry. Default limits:

| Route class | `per_min` | burst capacity |
|---|---|---|
| `/v1/captures` | 30 | 60 |
| `/v1/queries` | 20 | 40 |
| everything else | 60 | 120 |

To raise or lower the limits, set the env vars `RATE_LIMIT_CAPTURE_PER_MIN`,
`RATE_LIMIT_QUERY_PER_MIN`, `RATE_LIMIT_DEFAULT_PER_MIN`, and
`RATE_LIMIT_BURST_MULTIPLIER` in `.env` and `make rebuild`.

**Multi-process caveat.** The rate limiter uses in-process memory (a plain
Python dict per worker). If the server is ever scaled to multiple worker
processes (`uvicorn --workers N`) or multiple container replicas, each process
maintains its own independent bucket dict and a client can exceed the nominal
rate by routing requests across processes. In that scenario, replace the
module-level storage in `grove/core/rate_limit.py` with a Redis-backed
implementation (e.g. redis-py async + a Lua script for atomic
check-and-decrement).

---

## Nightly backup (§1.6)

The production Hetzner box runs a nightly `pg_dump` that writes a dated
custom-format archive to a Hetzner Storage Box (or Backblaze B2 bucket).
30-day retention.  The backup job is a host-level cron on the Hetzner box
(`/etc/cron.d/grove-backup` or equivalent) that executes roughly:

```bash
BACKUP_DIR=/mnt/storagebox/grove-backups   # or rclone-mounted B2 bucket
DATESTAMP=$(date -u +%Y-%m-%d)
docker compose -f $REPO_ROOT/docker-compose.yml exec -T postgres \
    pg_dump -U grove -d grove -Fc \
    > "${BACKUP_DIR}/grove-${DATESTAMP}.dump"
# prune files older than 30 days
find "${BACKUP_DIR}" -name 'grove-*.dump' -mtime +30 -delete
```

> **Note:** The backup job itself is not committed in this repo — it lives on
> the production host.  The paths above are the canonical convention; confirm
> `BACKUP_DIR` with the host's actual mount point after deploy.

---

## Restore drill

Run this drill any time you need to verify a backup, recover from data loss,
or satisfy the §1.6 exit criterion.  All commands are copy-pasteable.

### Step 1 — Pull the most recent backup to a scratch directory

On the Hetzner box (or from a machine with access to the backup storage):

```bash
BACKUP_DIR=/mnt/storagebox/grove-backups   # adjust to actual mount
SCRATCH=/tmp/grove-restore-$(date -u +%Y-%m-%d)
mkdir -p "${SCRATCH}"

# Copy the newest dated archive
LATEST=$(ls -t "${BACKUP_DIR}"/grove-*.dump | head -1)
cp "${LATEST}" "${SCRATCH}/grove.dump"
echo "Working with: ${LATEST}"
```

If the backup target is remote (e.g. Backblaze B2 via rclone):

```bash
rclone copy b2:grove-backups/"$(rclone ls b2:grove-backups | sort -k2 | tail -1 | awk '{print $2}')" "${SCRATCH}/"
# then rename to grove.dump as above
```

### Step 2 — Spin up a throwaway Postgres+pgvector container

Use the same image tag as the production compose stack (`pgvector/pgvector:pg16`):

```bash
docker run --rm -d \
    --name grove-drill \
    -e POSTGRES_DB=grove \
    -e POSTGRES_USER=grove \
    -e POSTGRES_PASSWORD=drillpass \
    -p 15433:5432 \
    pgvector/pgvector:pg16

# Wait until ready (usually < 5 s)
until docker exec grove-drill pg_isready -U grove -d grove -q; do sleep 1; done
echo "Ready"
```

### Step 3 — Create the pgvector extension and load the dump

```bash
docker exec grove-drill psql -U grove -d grove \
    -c "CREATE EXTENSION IF NOT EXISTS vector;"

docker cp "${SCRATCH}/grove.dump" grove-drill:/tmp/grove.dump
docker exec grove-drill \
    pg_restore -U grove -d grove --no-owner --no-privileges /tmp/grove.dump

echo "Restore complete"
```

> **Format note:** the dump is in PostgreSQL custom format (`-Fc`), so
> `pg_restore` is correct here — do NOT use `psql <` for custom-format dumps.

### Step 4 — Sanity-count queries

Run these inside the throwaway container (or via `psql -h localhost -p 15433 -U grove -d grove`):

```bash
docker exec grove-drill psql -U grove -d grove -c "
SELECT 'memories'          AS tbl, COUNT(*) FROM memories
UNION ALL
SELECT 'memory_chunks',         COUNT(*) FROM memory_chunks
UNION ALL
SELECT 'decisions',             COUNT(*) FROM decisions
UNION ALL
SELECT 'people_interactions',   COUNT(*) FROM people_interactions
UNION ALL
SELECT 'appointments',          COUNT(*) FROM appointments
UNION ALL
SELECT 'query_logs',            COUNT(*) FROM query_logs
UNION ALL
SELECT 'enrichment_state',      COUNT(*) FROM enrichment_state
ORDER BY tbl;
"
```

Also verify all migrations were applied (non-empty `alembic_version`):

```bash
docker exec grove-drill psql -U grove -d grove \
    -c "SELECT version_num FROM alembic_version;"
```

And confirm pgvector is present:

```bash
docker exec grove-drill psql -U grove -d grove \
    -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
```

### Step 5 — Compare against production counts (captured at backup time)

Before running the drill on production, capture a snapshot from the live DB:

```bash
# On the production host (Hetzner box), before/during the same backup window:
docker compose exec -T postgres psql -U grove -d grove -c "
SELECT 'memories'          AS tbl, COUNT(*) FROM memories
UNION ALL
SELECT 'memory_chunks',         COUNT(*) FROM memory_chunks
UNION ALL
SELECT 'decisions',             COUNT(*) FROM decisions
UNION ALL
SELECT 'people_interactions',   COUNT(*) FROM people_interactions
UNION ALL
SELECT 'appointments',          COUNT(*) FROM appointments
UNION ALL
SELECT 'query_logs',            COUNT(*) FROM query_logs
UNION ALL
SELECT 'enrichment_state',      COUNT(*) FROM enrichment_state
ORDER BY tbl;
" | tee "${SCRATCH}/prod-counts.txt"
```

After the restore, diff the counts:

```bash
docker exec grove-drill psql -U grove -d grove -c "
SELECT 'memories'          AS tbl, COUNT(*) FROM memories
UNION ALL
SELECT 'memory_chunks',         COUNT(*) FROM memory_chunks
UNION ALL
SELECT 'decisions',             COUNT(*) FROM decisions
UNION ALL
SELECT 'people_interactions',   COUNT(*) FROM people_interactions
UNION ALL
SELECT 'appointments',          COUNT(*) FROM appointments
UNION ALL
SELECT 'query_logs',            COUNT(*) FROM query_logs
UNION ALL
SELECT 'enrichment_state',      COUNT(*) FROM enrichment_state
ORDER BY tbl;
" | tee "${SCRATCH}/drill-counts.txt"

diff "${SCRATCH}/prod-counts.txt" "${SCRATCH}/drill-counts.txt"
```

A clean diff (no output) means all row counts match.

### Step 6 — Tear down the throwaway container

```bash
docker stop grove-drill
# The --rm flag on docker run ensures it is deleted automatically on stop.
```

---

## Restore drill — Last verified appendix

Update this table each time the drill is run.  The entry below is the initial
local dev-stack dry-run; a production drill is the operator's responsibility
and should be recorded here when done.

| Date | Environment | Who | Counts matched? | Notes |
|------|-------------|-----|-----------------|-------|
| 2026-05-15 | Local dev-stack dry-run | Margot (agent) | Yes — all 7 tables 0 rows (empty dev DB) | pgvector 0.8.2, image `pgvector/pgvector:pg16`, 8 tables restored incl. `alembic_version`. Production drill pending. |

**Counts from 2026-05-15 local dry-run:**

Source (dev DB):

```
         tbl         | count
---------------------+-------
 appointments        |     0
 decisions           |     0
 enrichment_state    |     0
 memories            |     0
 memory_chunks       |     0
 people_interactions |     0
 query_logs          |     0
```

Restored (throwaway container):

```
         tbl         | count
---------------------+-------
 appointments        |     0
 decisions           |     0
 enrichment_state    |     0
 memories            |     0
 memory_chunks       |     0
 people_interactions |     0
 query_logs          |     0
```

Diff: none (counts identical).

---

## Enrichment cron (systemd timer)

The hourly enrichment worker runs as a systemd timer on the host. Unit files live
in `ops/systemd/` and must be installed once after deploy.

### Operator prerequisites

1. Create the `grove` system user and add it to the `docker` group:

   ```bash
   sudo useradd --system --no-create-home grove
   sudo usermod -aG docker grove
   ```

2. Confirm the project is checked out at `$REPO_ROOT` (set in your deploy env,
   default `/opt/grove`). Update `WorkingDirectory=` in `grove-enrichment.service`
   if your checkout path differs.

3. Confirm the local Ollama server runs as `ollama.service` and is enabled on
   boot (`sudo systemctl enable --now ollama`). The enrichment unit is ordered
   `After=docker.service ollama.service` / `Wants=ollama.service` because the
   worker calls local models (gpt-oss-20b, bge-m3) through Ollama.

### Install the units

```bash
sudo cp $REPO_ROOT/ops/systemd/grove-enrichment.{service,timer} \
    /etc/systemd/system/
sudo systemctl daemon-reload
```

### Enable and start the timer

```bash
sudo systemctl enable --now grove-enrichment.timer
```

To disable (stops future runs; does not abort a run in progress):

```bash
sudo systemctl disable --now grove-enrichment.timer
```

### Trigger an ad-hoc run

```bash
sudo systemctl start grove-enrichment.service
```

### Read recent run logs

```bash
# Last 100 lines from all runs
journalctl -u grove-enrichment.service -n 100 --no-pager

# Follow live output during a run
journalctl -u grove-enrichment.service -f
```

### Verify the timer is scheduled

```bash
systemctl list-timers grove-enrichment.timer
```

### Post-downtime behaviour

The timer uses `Persistent=true`, so if the host was down (or the timer was
disabled) when a scheduled hourly window would have fired, systemd executes the
service once on the next boot to catch up. Only **one** catch-up run fires per
re-enable — not one per missed window — so a multi-hour outage results in a
single delayed run, not a flood.

This is usually desirable but can surprise operators: after a long outage the
enrichment worker can fire before the rest of the Docker stack is fully
healthy. If you've just rebooted the box or restored from a snapshot, either
let the full stack stabilise before enabling the timer, or temporarily stop
it during the startup window:

```bash
sudo systemctl stop grove-enrichment.timer
# ... wait for compose stack + database to be healthy ...
sudo systemctl start grove-enrichment.timer
```

### Alerting

V1 has no automated alerting. Runs are reviewed manually as part of the weekly
review cadence. Check for `enrichment_error` rows in the database or non-zero
exit codes in the journal if something appears wrong.

---

## Enrichment scheduler (macOS LaunchAgent)

On a macOS dev host there is no systemd. `ops/launchd/com.affinitybridge.grove-enrichment.plist`
is a LaunchAgent template that fires the same enrichment worker hourly, against
the local Docker Compose stack.

### Prerequisites

- Docker Desktop or OrbStack must be running whenever a scheduled window fires.
  If it isn't, the job exits non-zero immediately; launchd logs the failure and
  waits for the next hourly window — no retry storm.
- The compose stack (`make up`) must be up and the `app` container healthy.
  The LaunchAgent does not start the stack automatically.

### Missed-interval behaviour

`StartCalendarInterval` does **not** catch up missed runs. If the host is
asleep or off during a scheduled window, that enrichment run is silently
skipped — launchd will fire again at the next scheduled wall-clock time.
This is Apple-documented behaviour (macOS 10.15+) and is generally fine for
a dev host.

By contrast, the Linux systemd timer (`ops/systemd/grove-enrichment.timer`)
has `Persistent=true`, so it fires one catch-up run immediately after the
host wakes if a window was missed while it was down.

If you need to recover after a period of missed enrichment (e.g. the laptop
slept through several overnight windows), trigger a manual run:

```bash
launchctl kickstart gui/$(id -u)/com.affinitybridge.grove-enrichment
```

### Install

Replace the two placeholders in the template (`__REPO_ROOT__` and
`__USER_HOME__`) and drop the rendered plist into `~/Library/LaunchAgents/`:

```bash
REPO_ROOT="$HOME/Projects/grove"   # adjust to your actual checkout path

mkdir -p ~/Library/LaunchAgents ~/Library/Logs/grove

sed \
    -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__USER_HOME__|${HOME}|g" \
    "${REPO_ROOT}/ops/launchd/com.affinitybridge.grove-enrichment.plist" \
    > ~/Library/LaunchAgents/com.affinitybridge.grove-enrichment.plist

launchctl bootstrap gui/$(id -u) \
    ~/Library/LaunchAgents/com.affinitybridge.grove-enrichment.plist
```

Verify it is registered:

```bash
launchctl list | grep grove
# should show: -  0  com.affinitybridge.grove-enrichment
```

### Trigger an ad-hoc run

```bash
launchctl kickstart -k gui/$(id -u)/com.affinitybridge.grove-enrichment
```

### Read recent run output

```bash
tail -f ~/Library/Logs/grove/enrichment.out.log
tail -f ~/Library/Logs/grove/enrichment.err.log
```

### Unload / remove

```bash
launchctl bootout gui/$(id -u)/com.affinitybridge.grove-enrichment
rm ~/Library/LaunchAgents/com.affinitybridge.grove-enrichment.plist
```

### Docker binary path

`/usr/local/bin/docker` is the canonical symlink on both Homebrew Intel and
OrbStack macOS installs. If your Docker binary is elsewhere, update
`ProgramArguments[0]` in the installed plist and reload:

```bash
# Find your docker binary:
which docker

# After editing the installed plist, reload:
launchctl bootout gui/$(id -u)/com.affinitybridge.grove-enrichment
launchctl bootstrap gui/$(id -u) \
    ~/Library/LaunchAgents/com.affinitybridge.grove-enrichment.plist
```
