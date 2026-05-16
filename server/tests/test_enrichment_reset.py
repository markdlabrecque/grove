"""Tests for grove.enrichment.reset -- selective re-enrichment CLI (ticket #181).

Design choices exercised here:
- Target predicate: enriched=true AND (enriched_version IS NULL OR enriched_version < N)
  Memories with a NULL enriched_version but enriched=true are included because they
  were enriched before version tracking existed; they need re-processing at the new
  version just as much as explicitly-versioned rows.
- Fields reset: enriched=false, enriched_at=NULL, enrichment_error=NULL.
- enriched_version is left unchanged -- it records the version last used and is
  useful for diagnostics / auditing.
- Specialised-table rows are NOT deleted. Re-enrichment at a new version writes
  fresh rows via ON CONFLICT DO NOTHING upsert (idempotent at same version, additive
  at new version), so deleting existing rows is not needed and would lose history.

Coverage:
1. Happy path: --version-below 2 resets only rows with enriched_version < 2 (or NULL).
2. Dry-run path: --dry-run reports IDs but makes no DB changes.
3. No-match path: --version-below 1 with no qualifying rows exits 0 / reports zero.
4. Already-unenriched rows are untouched (enriched=false rows not double-reset).
5. Specialised-table rows are NOT deleted by reset.

Requires a real Postgres instance (DATABASE_URL from conftest / env).
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.models import Decision, Memory

_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_Session = async_sessionmaker(_engine, expire_on_commit=False)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_memory(
    *,
    enriched: bool,
    enriched_version: int | None,
    enrichment_error: str | None = None,
) -> Memory:
    enriched_at = datetime.now(tz=UTC) if enriched else None
    return Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Reset CLI test memory.",
        enriched=enriched,
        enriched_at=enriched_at,
        enriched_version=enriched_version,
        enrichment_error=enrichment_error,
        created_at=datetime.now(tz=UTC),
    )


async def _seed(session: AsyncSession, memories: list[Memory]) -> None:
    session.add_all(memories)
    await session.commit()


async def _cleanup(session: AsyncSession, ids: list[uuid.UUID]) -> None:
    for mem_id in ids:
        obj = await session.get(Memory, mem_id)
        if obj:
            await session.delete(obj)
    await session.commit()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def clean_enriched_memories() -> AsyncIterator[None]:
    """Wipe all enriched memories before each test.

    reset() operates on ALL qualifying rows in the database, so leftover
    enriched rows from other tests would corrupt count and ID assertions.
    """
    async with _Session() as session:
        result = await session.execute(select(Memory).where(Memory.enriched.is_(True)))
        for mem in result.scalars().all():
            await session.delete(mem)
        await session.commit()
    yield


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


async def test_reset_version_below_resets_only_qualifying_rows(
    db_session: AsyncSession,
) -> None:
    """--version-below 2 resets enriched rows with enriched_version in {None, 1}
    and leaves rows with enriched_version >= 2 untouched.

    Seed:
        row A: enriched=true,  enriched_version=None  -> should be reset
        row B: enriched=true,  enriched_version=1     -> should be reset (1 < 2)
        row C: enriched=true,  enriched_version=2     -> NOT reset (2 is not < 2)
        row D: enriched=true,  enriched_version=3     -> NOT reset (3 is not < 2)
    """
    from grove.enrichment.reset import reset

    row_a = _make_memory(enriched=True, enriched_version=None)
    row_b = _make_memory(enriched=True, enriched_version=1)
    row_c = _make_memory(enriched=True, enriched_version=2)
    row_d = _make_memory(enriched=True, enriched_version=3)
    ids = [row_a.id, row_b.id, row_c.id, row_d.id]

    await _seed(db_session, [row_a, row_b, row_c, row_d])
    try:
        result = await reset(version_below=2, dry_run=False)

        assert result.count == 2
        assert set(result.affected_ids) == {row_a.id, row_b.id}

        # Verify DB state: A and B are reset; C and D are unchanged.
        await db_session.refresh(row_a)
        await db_session.refresh(row_b)
        await db_session.refresh(row_c)
        await db_session.refresh(row_d)

        assert row_a.enriched is False
        assert row_a.enriched_at is None
        assert row_a.enrichment_error is None
        # enriched_version is intentionally left intact for diagnostic value.
        assert row_a.enriched_version is None

        assert row_b.enriched is False
        assert row_b.enriched_at is None
        assert row_b.enrichment_error is None
        # enriched_version is intentionally left intact for diagnostic value.
        assert row_b.enriched_version == 1

        assert row_c.enriched is True
        assert row_d.enriched is True
    finally:
        await _cleanup(db_session, ids)


async def test_dry_run_reports_ids_but_makes_no_changes(
    db_session: AsyncSession,
) -> None:
    """--dry-run returns the IDs that would be reset but does not modify any rows."""
    from grove.enrichment.reset import reset

    row_a = _make_memory(enriched=True, enriched_version=None)
    row_b = _make_memory(enriched=True, enriched_version=1)
    row_c = _make_memory(enriched=True, enriched_version=2)
    ids = [row_a.id, row_b.id, row_c.id]

    await _seed(db_session, [row_a, row_b, row_c])
    try:
        result = await reset(version_below=2, dry_run=True)

        assert result.count == 2
        assert set(result.affected_ids) == {row_a.id, row_b.id}

        # No DB changes should have occurred.
        await db_session.refresh(row_a)
        await db_session.refresh(row_b)
        await db_session.refresh(row_c)

        assert row_a.enriched is True, "dry-run must not modify enriched"
        assert row_a.enriched_at is not None, "dry-run must not clear enriched_at"
        # enriched_version must be unchanged — dry-run writes nothing.
        assert row_a.enriched_version is None
        assert row_b.enriched is True, "dry-run must not modify enriched"
        assert row_b.enriched_version == 1
        assert row_c.enriched_version == 2
    finally:
        await _cleanup(db_session, ids)


async def test_no_match_returns_zero_count(
    db_session: AsyncSession,
) -> None:
    """When no rows qualify, reset returns count=0 and an empty affected_ids list."""
    from grove.enrichment.reset import reset

    row_a = _make_memory(enriched=True, enriched_version=5)
    await _seed(db_session, [row_a])
    try:
        result = await reset(version_below=1, dry_run=False)

        assert result.count == 0
        assert result.affected_ids == []
    finally:
        await _cleanup(db_session, [row_a.id])


async def test_unenriched_rows_are_not_reset(
    db_session: AsyncSession,
) -> None:
    """enriched=false rows are outside the reset predicate and must not be touched.

    The predicate is: enriched=true AND (enriched_version IS NULL OR enriched_version < N).
    A row with enriched=false and enriched_version=1 must not appear in the result.
    """
    from grove.enrichment.reset import reset

    unenriched = _make_memory(enriched=False, enriched_version=1)
    unenriched.enriched_at = None  # confirm it's truly unenriched
    await _seed(db_session, [unenriched])
    try:
        result = await reset(version_below=5, dry_run=False)

        assert unenriched.id not in result.affected_ids

        # DB state unchanged.
        await db_session.refresh(unenriched)
        assert unenriched.enriched is False
    finally:
        await _cleanup(db_session, [unenriched.id])


async def test_specialised_table_rows_not_deleted_on_reset(
    db_session: AsyncSession,
) -> None:
    """reset() must NOT delete specialised-table rows for affected memories.

    Re-enrichment at a new PIPELINE_VERSION relies on insert_if_not_exists
    being a no-op at the same (memory_id, enrichment_version) and inserting a
    fresh row at a new version. Deleting existing rows would break that contract
    and lose history.

    This test:
    1. Creates a memory with enriched_version=1 and a Decision row at version 1.
    2. Resets with --version-below 2.
    3. Asserts the Decision row still exists.
    """
    from grove.enrichment.reset import reset

    memory = _make_memory(enriched=True, enriched_version=1)
    await _seed(db_session, [memory])

    # Insert a specialised-table row pointing at this memory.
    decision = Decision(
        id=uuid.uuid4(),
        memory_id=memory.id,
        enrichment_version=1,
        decision_maker="Alice",
        context="What to have for lunch",
        options=["salad", "sandwich"],
        chosen_option="salad",
        rationale="healthier",
        outcome=None,
        outcome_date=None,
        confidence=0.9,
    )
    db_session.add(decision)
    await db_session.commit()

    try:
        result = await reset(version_below=2, dry_run=False)

        assert memory.id in result.affected_ids

        # Decision row must still exist.
        fetched = await db_session.get(Decision, decision.id)
        assert fetched is not None, (
            "reset() must not delete specialised-table rows; "
            "re-enrichment uses idempotent upsert instead"
        )
    finally:
        # Decision is cascade-deleted with the memory.
        await _cleanup(db_session, [memory.id])


async def test_atomic_reset_skips_row_re_enriched_between_select_and_update(
    db_session: AsyncSession,
) -> None:
    """reset() must not overwrite a concurrent worker's re-enrichment.

    The race window in the old SELECT-then-UPDATE implementation: reset() selects
    qualifying rows, a concurrent worker re-enriches one of them (bumping
    enriched_version beyond version_below), then reset()'s UPDATE fires
    ``WHERE id IN (affected_ids)`` — which has no predicate re-check and
    overwrites the worker's result, resetting enriched back to false.

    The fix collapses SELECT + UPDATE into a single ``UPDATE … RETURNING`` with
    the predicate re-checked at write time.  A row that has moved to
    enriched_version >= version_below between the conceptual SELECT and UPDATE
    is excluded atomically.

    This test uses a module-level seam (``_test_after_select_hook``) to inject a
    concurrent worker bump between the SELECT and UPDATE in the old code path.
    In the new code there is no SELECT; the hook fires before the single
    UPDATE … RETURNING statement, so the predicate re-check at write time
    correctly excludes the already-bumped row.

    Seed:
        row: enriched=true, enriched_version=1  (qualifies for version_below=10)
    Injected hook (fires between SELECT and UPDATE):
        commits enriched_version=10, enriched=true in a separate session
    Expected after reset(version_below=10):
        count == 0  (row excluded because 10 is not < 10 at write time)
        DB state unchanged: enriched=true, enriched_version=10
    On the old SELECT-then-UPDATE code (regression):
        count == 1  (UPDATE WHERE id IN (…) ignores the predicate; overwrites worker)
        DB state: enriched=false (worker's re-enrichment is lost)
    """
    import grove.enrichment.reset as reset_module
    from grove.enrichment.reset import reset

    memory = _make_memory(enriched=True, enriched_version=1)
    await _seed(db_session, [memory])

    async def _bump_to_worker_version() -> None:
        """Simulate a worker re-enriching the row to version 10 before the UPDATE fires."""
        async with _Session() as side:
            await side.execute(
                update(Memory)
                .where(Memory.id == memory.id)
                .values(enriched=True, enriched_version=10)
            )
            await side.commit()

    reset_module._test_after_select_hook = _bump_to_worker_version
    try:
        result = await reset(version_below=10, dry_run=False, session=db_session)

        # The worker's re-enrichment must be preserved: the row must not appear
        # in affected_ids, and its DB state must reflect the worker's stamp.
        assert result.count == 0, (
            f"reset() wrongly reset a row the worker had already re-enriched "
            f"(expected count=0, got count={result.count})"
        )
        assert memory.id not in result.affected_ids

        await db_session.refresh(memory)
        assert memory.enriched is True, "worker's enriched=true must be preserved"
        assert memory.enriched_version == 10, "worker's enriched_version=10 must be preserved"
    finally:
        reset_module._test_after_select_hook = None
        await _cleanup(db_session, [memory.id])
