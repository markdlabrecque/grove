"""Enrichment worker entrypoint.

Invoked via ``python -m oracle.enrichment.run`` by cron (hourly).

Single-run lifecycle:
1. Insert an enrichment_state row with run_started_at and pipeline_version.
2. Fetch a batch of unenriched memories using FOR UPDATE SKIP LOCKED so
   concurrent runs claim disjoint subsets.
3. Call classify_and_write(memory) per memory inside its own transaction so
   one failure does not poison the rest of the batch.
4. Update the enrichment_state row with completion time and counts.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime

import structlog
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.models import EnrichmentState, Memory

logger = structlog.get_logger(__name__)

# Correlates with the classify.v1.yaml enrichment_version field.
PIPELINE_VERSION = 1


def _make_session_factory() -> async_sessionmaker[AsyncSession]:
    # NullPool: the worker is short-lived; connection-per-operation is fine and
    # avoids pool overhead in a cron context.
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    return async_sessionmaker(engine, expire_on_commit=False)


async def _fetch_batch(
    session: AsyncSession,
    batch_size: int,
) -> list[Memory]:
    """Fetch up to batch_size unenriched memories, locking them for this run.

    FOR UPDATE SKIP LOCKED: rows locked by another concurrent run are skipped
    rather than waited on, so two simultaneous workers claim disjoint sets.
    """
    result = await session.execute(
        select(Memory)
        .where(Memory.enriched.is_(False))
        .order_by(Memory.created_at)
        .limit(batch_size)
        .with_for_update(skip_locked=True)
    )
    return list(result.scalars().all())


async def run(
    batch_size: int = 50,
    classify_and_write: Callable[[Memory], None] | None = None,
) -> None:
    """Execute one enrichment pass.

    Args:
        batch_size: Maximum number of memories to process per run.
        classify_and_write: Called once per memory. Defaults to the stub
            (real implementation wired in #179/#180). Accepts a sync callable
            for simplicity; the worker is I/O-bound at the DB level.
    """
    if classify_and_write is None:
        classify_and_write = _stub_classify_and_write

    run_id = uuid.uuid4()
    log = logger.bind(run_id=str(run_id), batch_size=batch_size)
    log.info("enrichment_run.started")

    factory = _make_session_factory()

    # --- Insert enrichment_state row at run start ---
    state_id = uuid.uuid4()
    started_at = datetime.now(tz=UTC)
    async with factory() as session:
        state = EnrichmentState(
            id=state_id,
            run_started_at=started_at,
            pipeline_version=PIPELINE_VERSION,
        )
        session.add(state)
        await session.commit()

    # --- Fetch batch (held open so the locks persist across the batch loop) ---
    processed = 0
    errors = 0

    async with factory() as batch_session:
        memories = await _fetch_batch(batch_session, batch_size)
        log.info("enrichment_run.batch_fetched", count=len(memories))

        for memory in memories:
            memory_log = log.bind(memory_id=str(memory.id))

            # Each memory gets its own nested session so a failure is isolated.
            async with factory() as mem_session:
                try:
                    classify_and_write(memory)

                    # Mark memory enriched on success.
                    mem = await mem_session.get(Memory, memory.id)
                    if mem is not None:
                        mem.enriched = True
                        mem.enriched_at = datetime.now(tz=UTC)
                        mem.enriched_version = PIPELINE_VERSION
                        mem.enrichment_error = None
                    await mem_session.commit()
                    processed += 1
                    memory_log.info("enrichment_run.memory.ok")
                except Exception as exc:
                    await mem_session.rollback()
                    # Surface the error on the memory row so the next run retries.
                    async with factory() as err_session:
                        mem = await err_session.get(Memory, memory.id)
                        if mem is not None:
                            mem.enrichment_error = str(exc)
                        await err_session.commit()
                    errors += 1
                    processed += 1
                    memory_log.warning("enrichment_run.memory.error", error=str(exc))

    # --- Update enrichment_state row with completion ---
    finished_at = datetime.now(tz=UTC)
    async with factory() as session:
        row = await session.get(EnrichmentState, state_id)
        if row is not None:
            row.run_completed_at = finished_at
            row.memories_processed = processed
            row.errors = errors
        await session.commit()

    log.info(
        "enrichment_run.finished",
        processed=processed,
        errors=errors,
        duration_s=(finished_at - started_at).total_seconds(),
    )


def _stub_classify_and_write(memory: Memory) -> None:
    """Stub classifier — real implementation wired in tickets #179/#180."""
    pass


if __name__ == "__main__":
    import asyncio

    from oracle.core.logging import configure_logging

    configure_logging()
    asyncio.run(run())
