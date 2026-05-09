#!/usr/bin/env bash
# Renews the Tailscale cert and tells the running Apache container to reload
# gracefully. Safe to schedule weekly via cron/launchd; tailscale cert only
# refreshes when the existing cert is close to expiry.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

"$HERE/bootstrap-cert.sh"

cd "$ROOT"

if docker compose ps --status running --services | grep -q '^apache$'; then
  echo "→ Reloading Apache (graceful)"
  docker compose kill -s USR1 apache 2>/dev/null \
    || docker compose exec -T apache httpd -k graceful
else
  echo "→ Apache container is not running; skipping reload"
fi
