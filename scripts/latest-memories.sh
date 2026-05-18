#!/usr/bin/env bash
# Print the N most-recently captured memories from the local Grove database.
#
# Usage:
#   latest-memories.sh          # default: 5
#   latest-memories.sh 20       # show 20
#
# Runnable from any subdirectory of the repo — `git rev-parse` locates the
# working-tree root so `docker compose` picks up the right project.
set -euo pipefail

limit="${1:-5}"

if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: limit must be a positive integer (got: $limit)" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: must be run from inside the Grove git working tree" >&2
  exit 1
}
cd "$repo_root"

docker compose exec -T postgres psql -U grove -d grove -P pager=off <<SQL
\pset format wrapped
\pset columns 100
SELECT
  to_char(captured_at AT TIME ZONE 'America/Vancouver', 'YYYY-MM-DD HH24:MI') AS captured,
  source_modality                                                              AS modality,
  content
FROM memories
ORDER BY captured_at DESC NULLS LAST, created_at DESC
LIMIT ${limit};
SQL
