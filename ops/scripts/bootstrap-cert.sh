#!/usr/bin/env bash
# Issues (or refreshes) a Tailscale-managed Let's Encrypt cert for this host
# and drops the .crt/.key files into ops/certs/. Idempotent — re-run any time.
#
# Reads TAILSCALE_HOSTNAME from .env if present, otherwise falls back to a
# hard-coded default that matches example.env.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CERT_DIR="$ROOT/ops/certs"

if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$ROOT/.env"; set +a
fi

if [[ -z "${TAILSCALE_HOSTNAME:-}" ]]; then
  echo "error: TAILSCALE_HOSTNAME is not set." >&2
  echo "  Copy example.env to .env and fill in your tailnet hostname." >&2
  exit 1
fi
HOST="$TAILSCALE_HOSTNAME"

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo "→ Issuing/renewing Tailscale cert for $HOST"
echo "  (you may be prompted for sudo)"
sudo tailscale cert "$HOST"

# tailscale cert writes files owned by root mode 600. Apache runs as the
# 'daemon' user inside the httpd container; UIDs don't line up cleanly with
# host on macOS Docker, so we make the files world-readable. This is dev-only
# on a single-user laptop on a private tailnet — acceptable trade-off.
sudo chmod 644 "$HOST.crt" "$HOST.key"

echo "→ Done:"
ls -la "$HOST".*
