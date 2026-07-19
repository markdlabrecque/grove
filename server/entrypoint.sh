#!/bin/sh
# Applies Alembic migrations before handing off to the app process (#519).
#
# alembic upgrade head is idempotent — a no-op when the DB is already at
# head — and exits non-zero on migration failure. Combined with `set -e`,
# a failed migration aborts the container before uvicorn ever starts, so we
# never serve requests against a half-migrated schema.

set -e

alembic upgrade head

exec "$@"
