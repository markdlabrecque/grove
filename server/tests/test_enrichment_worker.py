"""Integration tests for oracle.enrichment.run (worker entrypoint).

TDD red commit — these tests fail until the implementation is in place.

Coverage:
- Integration: 5 unenriched memories → run() → enrichment_state row created,
  stub called per-memory.
- Concurrency: two parallel run() calls do not double-claim any memory.
- Per-memory transaction isolation: stub raising on memory 3 does not block
  memory 4 from being processed.

Requires a real Postgres+pgvector instance (DATABASE_URL from conftest / env).
No OpenAI/OpenRouter calls — the classifier is a stub throughout.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from unittest.mock import MagicMock

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.models import EnrichmentState, Memory

# NullPool: each test gets fresh connections; avoids "another operation in
# progress" when test helpers and the worker share the same event loop.
_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_Session = async_sessionmaker(_engine, expire_on_commit=False)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_memory(*, enriched: bool = False) -> Memory:
    return Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Test memory content.",
        enriched=enriched,
        created_at=datetime.now(tz=UTC),
    )


async def _seed_memories(session: AsyncSession, n: int) -> list[Memory]:
    memories = [_make_memory() for _ in range(n)]
    session.add_all(memories)
    await session.commit()
    return memories


async def _cleanup(session: AsyncSession, memories: list[Memory]) -> None:
    """Delete test memories and any enrichment_state rows created during the test."""
    for m in memories:
        obj = await session.get(Memory, m.id)
        if obj:
            await session.delete(obj)
    await session.flush()

    rows = await session.execute(select(EnrichmentState))
    for row in rows.scalars().all():
        await session.delete(row)
    await session.commit()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


# ---------------------------------------------------------------------------
# Test: basic integration — enrichment_state row + stub called per memory
# ---------------------------------------------------------------------------


async def test_run_creates_enrichment_state_and_calls_stub(
    db_session: AsyncSession,
) -> None:
    """run() inserts an enrichment_state row and calls the stub for each memory."""
    from oracle.enrichment.run import run

    memories = await _seed_memories(db_session, 5)
    try:
        stub = MagicMock(return_value=None)
        await run(batch_size=10, classify_and_write=stub)

        # Exactly one enrichment_state row should exist after a clean run.
        result = await db_session.execute(select(EnrichmentState))
        state_rows = result.scalars().all()
        assert len(state_rows) == 1

        state = state_rows[0]
        assert state.run_started_at is not None
        assert state.run_completed_at is not None
        assert state.run_completed_at >= state.run_started_at
        assert state.memories_processed == 5
        assert state.errors == 0

        # Stub was called once per memory.
        assert stub.call_count == 5
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test: concurrency — two parallel run() calls must not double-claim
# ---------------------------------------------------------------------------


async def test_concurrent_runs_do_not_double_claim(
    db_session: AsyncSession,
) -> None:
    """Two simultaneous run() calls each claim a disjoint subset of memories."""
    from oracle.enrichment.run import run

    memories = await _seed_memories(db_session, 6)
    claimed: list[uuid.UUID] = []

    def tracking_stub(memory: Memory) -> None:
        claimed.append(memory.id)

    try:
        await asyncio.gather(
            run(batch_size=10, classify_and_write=tracking_stub),
            run(batch_size=10, classify_and_write=tracking_stub),
        )

        # Every memory claimed at most once (SKIP LOCKED prevents double-claim).
        assert len(claimed) == len(set(claimed)), (
            "At least one memory was processed by both workers"
        )
        # All 6 memories processed in total across both runs.
        assert len(claimed) == 6
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test: per-memory transaction isolation — failure on N=3 does not block N=4
# ---------------------------------------------------------------------------


async def test_per_memory_isolation_failure_does_not_block_others(
    db_session: AsyncSession,
) -> None:
    """A stub that raises on the third memory must not prevent the fourth from being processed."""
    from oracle.enrichment.run import run

    memories = await _seed_memories(db_session, 5)
    processed: list[uuid.UUID] = []
    call_count = 0

    def flaky_stub(memory: Memory) -> None:
        nonlocal call_count
        call_count += 1
        if call_count == 3:
            raise RuntimeError("simulated enrichment failure on memory 3")
        processed.append(memory.id)

    try:
        await run(batch_size=10, classify_and_write=flaky_stub)

        # 4 out of 5 memories processed successfully; 1 error recorded.
        result = await db_session.execute(select(EnrichmentState))
        state = result.scalar_one()
        assert state.memories_processed == 5
        assert state.errors == 1

        # The failed memory should have enrichment_error set and enriched=False.
        result2 = await db_session.execute(
            select(Memory).where(Memory.enrichment_error.isnot(None))
        )
        errored = result2.scalars().all()
        assert len(errored) == 1
        assert errored[0].enriched is False

        # The other 4 memories should be marked enriched.
        result3 = await db_session.execute(select(Memory).where(Memory.enriched.is_(True)))
        enriched_memories = result3.scalars().all()
        enriched_ids = {m.id for m in enriched_memories}
        # All test memories that were processed should be in the enriched set.
        assert len(enriched_ids.intersection({m.id for m in memories})) == 4
    finally:
        await _cleanup(db_session, memories)
