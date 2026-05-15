"""Enrichment worker entrypoint.

Invoked via ``python -m oracle.enrichment.run`` by cron (hourly).

Single-run lifecycle:
1. Insert an enrichment_state row with run_started_at and pipeline_version.
2. Fetch a batch of unenriched memories using FOR UPDATE SKIP LOCKED so
   concurrent runs claim disjoint subsets.
3. Call classify_and_write(memory, session, report=report) per memory inside
   its own transaction so one failure does not poison the rest of the batch.
4. Serialise the RunReport to enrichment_state.notes (JSONB) and emit a
   structured log line.
5. Update the enrichment_state row with completion time and counts.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable, Coroutine
from datetime import UTC, datetime
from typing import Any

import structlog
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.enrichment.report import RunReport
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
    classify_and_write: Callable[[Memory, AsyncSession], Coroutine[Any, Any, None]] | None = None,
) -> None:
    """Execute one enrichment pass.

    Args:
        batch_size: Maximum number of memories to process per run.
        classify_and_write: Async callable invoked once per memory with the
            memory, its per-memory session, and a ``report`` keyword argument
            carrying the shared RunReport for this run.  The callable owns the
            session commit (success path) and rollback (failure path), so the
            worker must NOT commit or rollback after the call returns.  Defaults
            to the real orchestrator implementation from oracle.enrichment.orchestrator.
    """
    if classify_and_write is None:
        from oracle.enrichment.orchestrator import (
            classify_and_write as _real_classify_and_write,
        )

        classify_and_write = _real_classify_and_write

    run_id = uuid.uuid4()
    log = logger.bind(run_id=str(run_id), batch_size=batch_size)
    log.info("enrichment_run.started")

    factory = _make_session_factory()
    report = RunReport()

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

    # --- Fetch batch ---
    processed = 0
    errors = 0

    async with factory() as batch_session:
        memories = await _fetch_batch(batch_session, batch_size)
        memory_ids = [m.id for m in memories]
        # Release FOR UPDATE locks immediately. The purpose of SKIP LOCKED is to
        # prevent a *concurrent* worker from claiming the same rows during the
        # fetch. Once we hold the IDs we own, we don't need the locks — the rapid
        # enriched=True write per memory prevents re-claim on the next run.
        await batch_session.commit()

    log.info("enrichment_run.batch_fetched", count=len(memory_ids))

    for memory_id in memory_ids:
        memory_log = log.bind(memory_id=str(memory_id))

        # Each memory gets its own session so a failure is isolated.
        # classify_and_write owns the session commit (or rollback) — the
        # worker must not commit after returning.
        async with factory() as mem_session:
            try:
                mem = await mem_session.get(Memory, memory_id)
                if mem is not None:
                    await classify_and_write(mem, mem_session, report=report)  # type: ignore[call-arg]
                else:
                    await mem_session.commit()
                processed += 1
                memory_log.info("enrichment_run.memory.ok")
            except Exception as exc:
                await mem_session.rollback()
                # Unexpected exception (not handled by the orchestrator).
                # Surface on the memory row so the next run retries.
                async with factory() as err_session:
                    mem = await err_session.get(Memory, memory_id)
                    if mem is not None:
                        mem.enrichment_error = str(exc)
                    await err_session.commit()
                errors += 1
                processed += 1
                memory_log.warning("enrichment_run.memory.error", error=str(exc))

    # --- Serialise RunReport and update enrichment_state row ---
    finished_at = datetime.now(tz=UTC)
    report_dict = report.to_dict()
    async with factory() as session:
        row = await session.get(EnrichmentState, state_id)
        if row is not None:
            row.run_completed_at = finished_at
            row.memories_processed = processed
            row.errors = errors
            row.notes = report_dict
        await session.commit()

    log.info(
        "enrichment_run.report",
        **report_dict,
    )
    log.info(
        "enrichment_run.finished",
        processed=processed,
        errors=errors,
        duration_s=(finished_at - started_at).total_seconds(),
    )
