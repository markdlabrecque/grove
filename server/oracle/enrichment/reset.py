"""Selective re-enrichment CLI (ticket #181).

Invoked as::

    python -m oracle.enrichment.reset --version-below N [--dry-run]

Resets memories so they will be picked up by the next enrichment worker pass.

Target predicate
----------------
``enriched = true AND (enriched_version IS NULL OR enriched_version < N)``

The NULL case captures memories that were enriched before the enriched_version
column existed (or before the pipeline version was stamped). They need
re-processing at the new version just as much as rows with an explicit old
version.

Fields reset
------------
- ``enriched``         → false   (re-enqueues the row for the next worker run)
- ``enriched_at``      → NULL    (no longer enriched, so no timestamp)
- ``enrichment_error`` → NULL    (clear any previous failure message)

Fields left alone
-----------------
- ``enriched_version`` is intentionally NOT cleared. It records which pipeline
  version was used for the last enrichment and is useful for diagnostics.

Specialised-table rows
----------------------
NOT deleted. Re-enrichment at a new PIPELINE_VERSION relies on
``insert_if_not_exists`` (ON CONFLICT DO NOTHING on (memory_id,
enrichment_version)): a row at the same version is a no-op; a row at a new
version is a fresh insert. Deleting existing rows is therefore unnecessary and
would lose potentially valuable history.
"""

from __future__ import annotations

import argparse
import asyncio
import uuid
from dataclasses import dataclass, field

import structlog
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.models import Memory

logger = structlog.get_logger(__name__)


@dataclass
class ResetResult:
    """Summary returned by :func:`reset`."""

    count: int
    affected_ids: list[uuid.UUID] = field(default_factory=list)
    dry_run: bool = False


async def reset(
    *,
    version_below: int,
    dry_run: bool = False,
    session: AsyncSession | None = None,
) -> ResetResult:
    """Reset memories whose enriched_version is below *version_below*.

    Args:
        version_below: Reset enriched memories with enriched_version < this value
            (or enriched_version IS NULL).
        dry_run: If True, identify qualifying rows but do not modify them.
        session: Optional externally-managed session (used in tests). When None,
            a fresh session is created from settings.DATABASE_URL.

    Returns:
        A :class:`ResetResult` with the count and IDs of affected rows.
    """
    from oracle.core.config import settings

    log = logger.bind(version_below=version_below, dry_run=dry_run)

    async def _run(s: AsyncSession) -> ResetResult:
        # Identify qualifying rows.
        stmt = select(Memory.id).where(
            Memory.enriched.is_(True),
            # enriched_version IS NULL OR enriched_version < version_below
            (Memory.enriched_version.is_(None) | (Memory.enriched_version < version_below)),
        )
        result = await s.execute(stmt)
        affected_ids: list[uuid.UUID] = list(result.scalars().all())

        if not dry_run and affected_ids:
            await s.execute(
                update(Memory)
                .where(Memory.id.in_(affected_ids))
                .values(enriched=False, enriched_at=None, enrichment_error=None)
            )
            await s.commit()

        return ResetResult(count=len(affected_ids), affected_ids=affected_ids, dry_run=dry_run)

    if session is not None:
        return await _run(session)

    # Own the session lifecycle when no session is injected.
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        result_obj = await _run(s)

    log.info(
        "enrichment_reset.done",
        count=result_obj.count,
        dry_run=dry_run,
    )
    return result_obj


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m oracle.enrichment.reset",
        description=(
            "Reset enriched memories below a pipeline version so the next "
            "enrichment worker run re-processes them."
        ),
    )
    parser.add_argument(
        "--version-below",
        type=int,
        required=True,
        metavar="N",
        help=(
            "Reset memories with enriched_version < N (or NULL) that are "
            "currently marked enriched=true."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Print what would be reset without making any changes.",
    )
    return parser


async def _main() -> None:
    from oracle.core.logging import configure_logging

    configure_logging()

    parser = _build_parser()
    args = parser.parse_args()

    result = await reset(version_below=args.version_below, dry_run=args.dry_run)

    if result.count == 0:
        print("No memories matched.")
        return

    prefix = "[dry-run] Would reset" if result.dry_run else "Reset"
    print(f"{prefix} {result.count} memory row(s).")

    # Print sample IDs (up to 10) for quick visual verification.
    sample = result.affected_ids[:10]
    for mem_id in sample:
        print(f"  {mem_id}")
    if result.count > 10:
        print(f"  ... and {result.count - 10} more")


if __name__ == "__main__":
    asyncio.run(_main())
