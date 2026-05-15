"""Integration tests for oracle.enrichment.run (worker entrypoint).

Coverage:
- Integration: 5 unenriched memories -> run() -> enrichment_state row created,
  stub called per-memory.
- Concurrency: two parallel run() calls leave all memories enriched.
- Per-memory transaction isolation: stub raising on memory 3 does not block
  memory 4 from being processed.
- Deadlock regression: batch_session must commit before the per-memory loop so
  that mem_session's UPDATE is not blocked by the FOR UPDATE row lock.

Requires a real Postgres+pgvector instance (DATABASE_URL from conftest / env).
No OpenAI/OpenRouter calls -- the classifier is a stub throughout.

All run() calls are wrapped in asyncio.wait_for with a 15-second timeout.
This prevents CI hangs if the batch-session deadlock is reintroduced -- the
timeout converts an indefinite hang into a fast failure.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from unittest.mock import AsyncMock

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

# Generous but finite: real runs on 3-6 rows complete in well under 1 s.
# If this fires, something is blocking (e.g. a reintroduced deadlock).
_RUN_TIMEOUT = 15.0


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


async def _run_with_timeout(
    *args: object,
    timeout: float = _RUN_TIMEOUT,
    **kwargs: object,
) -> None:
    """Call run() with a timeout guard.

    Converts an indefinite hang (e.g. from a deadlock) into a fast
    pytest.fail so CI does not block for minutes.
    """
    from oracle.enrichment.run import run

    try:
        await asyncio.wait_for(run(*args, **kwargs), timeout=timeout)  # type: ignore[arg-type]
    except TimeoutError:
        pytest.fail(
            f"run() did not complete within {timeout}s -- likely a deadlock "
            "caused by batch_session holding FOR UPDATE locks across the "
            "per-memory loop."
        )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def clean_enrichment_tables() -> AsyncIterator[None]:
    """Wipe enrichment-related rows before each test.

    The worker processes *all* unenriched memories, so leftover rows from a
    previous test run (or a previous test in the same session) would corrupt
    count assertions. This fixture ensures a clean slate.
    """
    async with _Session() as session:
        # Pre-test: delete all unenriched memories and all enrichment_state rows.
        # Enriched memories are left alone -- they won't be picked up by the
        # worker's WHERE enriched = false filter.
        result = await session.execute(select(Memory).where(Memory.enriched.is_(False)))
        for mem in result.scalars().all():
            await session.delete(mem)
        result2 = await session.execute(select(EnrichmentState))
        for row in result2.scalars().all():
            await session.delete(row)
        await session.commit()
    yield
    # Post-test cleanup is handled by each test's finally block (_cleanup).


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


# ---------------------------------------------------------------------------
# Test: basic integration -- enrichment_state row + stub called per memory
# ---------------------------------------------------------------------------


async def test_run_creates_enrichment_state_and_calls_stub(
    db_session: AsyncSession,
) -> None:
    """run() inserts an enrichment_state row and calls the stub for each memory."""
    memories = await _seed_memories(db_session, 5)
    try:
        stub = AsyncMock(return_value=None)
        await _run_with_timeout(batch_size=10, classify_and_write=stub)

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
# Test: concurrency -- two parallel run() calls must not crash, all memories
# must be enriched
# ---------------------------------------------------------------------------


async def test_concurrent_runs_all_memories_enriched(
    db_session: AsyncSession,
) -> None:
    """Two simultaneous run() calls must leave all memories enriched without crashing.

    With the batch-session fix (commit immediately after fetch), FOR UPDATE SKIP
    LOCKED prevents double-claim between truly concurrent *processes* (different
    OS-level connections racing the SELECT). Within a single asyncio event loop,
    coroutines interleave cooperatively -- both workers can fetch the same rows
    after the first worker's batch_session commits.

    The double-claim risk for specialised-table inserts is closed by the
    (memory_id, enrichment_version) unique constraint + ON CONFLICT DO NOTHING
    upsert guard added in #201. Duplicate-row assertions live in
    test_specialized_table_upsert.py::test_worker_concurrent_runs_no_duplicate_specialised_rows.

    This test asserts the two invariants that matter for the Memory table itself:
    1. No crash or exception propagates out of either run() call.
    2. Every seeded memory is marked enriched after both runs complete.
    """
    memories = await _seed_memories(db_session, 6)
    memory_ids = {m.id for m in memories}

    try:

        async def _enriching_stub(m: Memory, s: AsyncSession, **kwargs: object) -> None:
            from datetime import UTC
            from datetime import datetime as _dt

            from oracle.enrichment.run import PIPELINE_VERSION

            m.enriched = True
            m.enriched_at = _dt.now(tz=UTC)
            m.enriched_version = PIPELINE_VERSION
            m.enrichment_error = None
            await s.commit()

        await asyncio.gather(
            _run_with_timeout(batch_size=10, classify_and_write=_enriching_stub),
            _run_with_timeout(batch_size=10, classify_and_write=_enriching_stub),
        )

        # All 6 test memories must be enriched -- no memory left behind.
        result = await db_session.execute(select(Memory).where(Memory.enriched.is_(True)))
        enriched_ids = {m.id for m in result.scalars().all()}
        assert memory_ids.issubset(enriched_ids), (
            f"Some memories were not enriched: {memory_ids - enriched_ids}"
        )
    finally:
        await _cleanup(db_session, memories)


# ---------------------------------------------------------------------------
# Test: per-memory transaction isolation -- failure on N=3 does not block N=4
# ---------------------------------------------------------------------------


async def test_per_memory_isolation_failure_does_not_block_others(
    db_session: AsyncSession,
) -> None:
    """A stub that raises on the third memory must not prevent the fourth from being processed."""
    memories = await _seed_memories(db_session, 5)
    processed: list[uuid.UUID] = []
    call_count = 0

    async def flaky_stub(memory: Memory, session: AsyncSession, **kwargs: object) -> None:
        nonlocal call_count
        call_count += 1
        if call_count == 3:
            raise RuntimeError("simulated enrichment failure on memory 3")
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        memory.enriched = True
        memory.enriched_at = _dt.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None
        processed.append(memory.id)
        await session.commit()

    try:
        await _run_with_timeout(batch_size=10, classify_and_write=flaky_stub)

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


# ---------------------------------------------------------------------------
# Test: deadlock regression -- run() must not hang when mem_session UPDATEs
# ---------------------------------------------------------------------------


async def test_for_update_lock_released_before_per_memory_update(
    db_session: AsyncSession,
) -> None:
    """Regression guard: run() must complete even when per-memory UPDATEs are in flight.

    Before the fix, batch_session held FOR UPDATE locks on the fetched rows for
    the entire per-memory loop. The per-memory work issues
    UPDATE memories SET enriched=True (inside mem_session.commit()), which
    blocks forever waiting for the lock held by batch_session.

    The fix: commit batch_session immediately after extracting the memory IDs,
    before entering the per-memory loop. Once batch_session commits, its FOR
    UPDATE locks are released and mem_session.commit() can proceed.

    Red/green: revert the ``await batch_session.commit()`` in run.py to run
    *after* the per-memory loop and this test (plus the other run()-based
    tests) will fail with a 15-second timeout from _run_with_timeout. With the
    fix, run() completes in well under 1 s.

    Part 2 directly verifies the DB-level lock mechanic that the fix relies on:
    a second connection can UPDATE a row only after the first connection's FOR
    UPDATE transaction commits.
    """
    from oracle.enrichment.run import _make_session_factory

    factory = _make_session_factory()

    # --- Part 1: run() must complete within the timeout ---
    memories = await _seed_memories(db_session, 3)

    async def _enriching_stub(m: Memory, s: AsyncSession, **kwargs: object) -> None:
        from datetime import UTC
        from datetime import datetime as _dt

        from oracle.enrichment.run import PIPELINE_VERSION

        m.enriched = True
        m.enriched_at = _dt.now(tz=UTC)
        m.enriched_version = PIPELINE_VERSION
        m.enrichment_error = None
        await s.commit()

    try:
        await _run_with_timeout(batch_size=10, classify_and_write=_enriching_stub)
        # All 3 memories must be enriched -- only possible if mem_session.commit()
        # was not blocked by batch_session's FOR UPDATE lock.
        result = await db_session.execute(
            select(Memory).where(
                Memory.id.in_([m.id for m in memories]),
                Memory.enriched.is_(True),
            )
        )
        enriched = result.scalars().all()
        assert len(enriched) == 3, (
            f"Only {len(enriched)}/3 memories were enriched -- "
            "mem_session.commit() may have been blocked by batch_session's lock."
        )
    finally:
        await _cleanup(db_session, memories)

    # --- Part 2: direct DB-level lock verification ---
    # Confirm that a FOR UPDATE commit releases the row lock, allowing a second
    # connection's UPDATE to succeed within a tight timeout.
    mem_id = uuid.uuid4()
    async with _Session() as s:
        s.add(
            Memory(
                id=mem_id,
                client_id=uuid.uuid4(),
                content="lock test",
                enriched=False,
                created_at=datetime.now(tz=UTC),
            )
        )
        await s.commit()

    try:
        async with factory() as batch_session:
            result = await batch_session.execute(
                select(Memory).where(Memory.id == mem_id).with_for_update(skip_locked=True)
            )
            locked = result.scalars().all()
            assert len(locked) == 1, "Memory was not locked -- test setup failed"
            # Release the FOR UPDATE lock (as the fix does before the loop).
            await batch_session.commit()

        # After batch_session commits, a second connection must be able to UPDATE
        # the row without blocking.
        async with factory() as mem_session:
            try:
                mem = await mem_session.get(Memory, mem_id)
                assert mem is not None
                mem.enriched = True
                await asyncio.wait_for(mem_session.commit(), timeout=3.0)
            except TimeoutError:
                pytest.fail(
                    "mem_session.commit() timed out -- the FOR UPDATE lock was "
                    "not released. batch_session.commit() must be called before "
                    "any per-memory UPDATE."
                )
    finally:
        async with _Session() as s:
            obj = await s.get(Memory, mem_id)
            if obj:
                await s.delete(obj)
            await s.commit()
