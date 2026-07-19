#!/usr/bin/env bash
# Nightly encrypted Postgres backup: pg_dump (from the running `postgres`
# compose service) -> age-encrypt to a recipient PUBLIC key -> upload to
# Backblaze B2 via rclone.
#
# AUTHORED BUT UNVERIFIED (#526): written while the deploy box is not yet
# reachable. `bash -n` and `shellcheck` clean locally, but no real run
# against a live stack has been performed. Run it by hand once and confirm
# a successful upload before trusting the timer unattended -- see
# ops/RUNBOOK.md, "Nightly backup" section.
#
# Safety model: the box holds only the age RECIPIENT (public) key, via
# AGE_RECIPIENT below. The matching age PRIVATE key never touches this
# host -- it stays off-box with the operator. A compromised box can
# therefore produce backups but can never decrypt them.
#
# This script never deletes anything, locally or remotely. Retention is a
# B2 lifecycle rule (see ops/RUNBOOK.md) -- a backup script that prunes its
# own uploads is a footgun: a bug here could silently delete every copy.
#
# Required env (read from $REPO_ROOT/.env if present; see example.env):
#   AGE_RECIPIENT   age public key, e.g. age1qqqqqqqqqq... (from `age-keygen`)
#   RCLONE_REMOTE   rclone destination, e.g. b2:grove-backups (a `b2:`
#                   remote + bucket/prefix, configured via `rclone config`)
#
# Every failure path below exits non-zero and logs to stderr (captured by
# journald via the grove-backup.service unit) so a failed or truncated
# dump is never uploaded as if it were good.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$ROOT/.env"; set +a
fi

if [[ -z "${AGE_RECIPIENT:-}" ]]; then
  echo "error: AGE_RECIPIENT is not set." >&2
  echo "  Generate a keypair with 'age-keygen' OFF this box, keep the private" >&2
  echo "  key with the operator, and set AGE_RECIPIENT to the public key" >&2
  echo "  ('# public key: age1...' line) in .env. See ops/RUNBOOK.md." >&2
  exit 1
fi

if [[ -z "${RCLONE_REMOTE:-}" ]]; then
  echo "error: RCLONE_REMOTE is not set (e.g. RCLONE_REMOTE=b2:grove-backups)." >&2
  echo "  See ops/RUNBOOK.md for the rclone B2 remote setup." >&2
  exit 1
fi

for bin in docker age rclone; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: required binary '$bin' not found on PATH." >&2
    exit 1
  fi
done

cd "$ROOT"

TIMESTAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
WORKDIR="$(mktemp -d)"
# Always clean up the scratch dir -- it holds a plaintext DB dump until the
# encrypt step, and we don't want that lingering on disk on any exit path.
trap 'rm -rf "$WORKDIR"' EXIT

DUMP_FILE="$WORKDIR/grove-${TIMESTAMP}.dump"
ENC_FILE="${DUMP_FILE}.age"

echo "→ Dumping grove database (pg_dump -Fc) to ${DUMP_FILE}"
docker compose exec -T postgres pg_dump -Fc -U grove grove > "$DUMP_FILE"

# Guard 1: the dump must exist and be non-empty. A crashed or truncated
# pg_dump can still leave a zero-byte (or missing) file in some failure
# modes -- never trust the exit code alone before shipping the artifact.
if [[ ! -s "$DUMP_FILE" ]]; then
  echo "error: pg_dump produced an empty or missing file -- aborting, nothing uploaded." >&2
  exit 1
fi

# Guard 2: confirm the archive is structurally valid before we encrypt and
# ship it. pg_restore --list only reads the table of contents, so this is
# cheap even for a large dump, and it catches truncation/corruption that a
# mere non-empty check would miss.
echo "→ Verifying archive integrity (pg_restore --list)"
if ! docker compose exec -T postgres pg_restore --list < "$DUMP_FILE" > /dev/null; then
  echo "error: pg_restore --list failed against the dump -- archive is corrupt or truncated, aborting." >&2
  exit 1
fi

echo "→ Encrypting to ${ENC_FILE}"
age -r "$AGE_RECIPIENT" -o "$ENC_FILE" "$DUMP_FILE"

if [[ ! -s "$ENC_FILE" ]]; then
  echo "error: age produced an empty or missing file -- aborting, nothing uploaded." >&2
  exit 1
fi

echo "→ Uploading to ${RCLONE_REMOTE}/"
rclone copy "$ENC_FILE" "${RCLONE_REMOTE}/" --checksum

REMOTE_NAME="$(basename "$ENC_FILE")"
echo "→ Confirming ${REMOTE_NAME} landed remotely"
if ! rclone lsf "${RCLONE_REMOTE}/" | grep -qxF "$REMOTE_NAME"; then
  echo "error: ${REMOTE_NAME} not found at ${RCLONE_REMOTE}/ after upload -- treat this run as failed." >&2
  exit 1
fi

echo "✓ Backup complete: ${REMOTE_NAME} ($(du -h "$ENC_FILE" | cut -f1) encrypted, uploaded to ${RCLONE_REMOTE}/)"
