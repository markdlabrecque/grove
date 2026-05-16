"""Tests for idempotent specialised-table writes (ticket #201).

The FOR UPDATE SKIP LOCKED semantics in the enrichment worker were weakened by
the batch-session commit fix in #178/#199: after that commit, concurrent
in-process coroutines can claim the same memory IDs and attempt duplicate
specialised-table inserts.

Resolution (a): unique constraint on (memory_id, enrichment_version) per
specialised table + ON CONFLICT DO NOTHING upsert helper so duplicate calls
are safe no-ops rather than IntegrityErrors.

Coverage (per #201 acceptance criteria and the TDD amendment completeness rule):
1. Happy path / concurrency: concurrent inserts for same (memory_id, version)
   produce exactly one row, no error surfaced.
2. Idempotence: calling insert_if_not_exists twice with same args → one row.
3. Negative / re-enrichment: a *different* enrichment_version for the same
   memory IS allowed (constraint must not block re-enrichment).
4. Worker-level: the loosened concurrency test in test_enrichment_worker.py is
   supplemented with a test that asserts no duplicate specialised rows appear
   after two concurrent writes targeting the same (memory_id, version).

Requires a real Postgres instance (DATABASE_URL from conftest / env).
No OpenAI/OpenRouter calls.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.models import Appointment, Decision, Memory, PeopleInteraction, Task

_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_Session = async_sessionmaker(_engine, expire_on_commit=False)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_memory() -> Memory:
    return Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Test memory for upsert guard.",
        enriched=False,
        created_at=datetime.now(tz=UTC),
    )


async def _seed_memory(session: AsyncSession) -> Memory:
    m = _make_memory()
    session.add(m)
    await session.commit()
    return m


async def _delete_memory(session: AsyncSession, memory: Memory) -> None:
    obj = await session.get(Memory, memory.id)
    if obj:
        await session.delete(obj)
    await session.commit()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


# ---------------------------------------------------------------------------
# Test 1: Idempotence — calling insert_if_not_exists twice yields one row
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "model_class,kwargs",
    [
        (
            Decision,
            {
                "decision_maker": "Alice",
                "context": "idempotence test",
                "options": ["A", "B"],
                "chosen_option": "A",
                "rationale": "Best fit.",
                "outcome": None,
                "outcome_date": None,
                "confidence": 0.9,
            },
        ),
        (
            PeopleInteraction,
            {
                "person_name": "Bob",
                "interaction_medium": "email",
                "topics": ["testing"],
                "next_steps": ["follow up"],
                "confidence": 0.85,
            },
        ),
        (
            Task,
            {
                "description": "Write idempotence test",
                "due_date": None,
                "status": "open",
                "related_people": ["Carol"],
                "confidence": 0.88,
            },
        ),
        (
            Appointment,
            {
                "title": "Sprint review",
                "starts_at": None,
                "ends_at": None,
                "location": "Zoom",
                "participants": ["Dave"],
                "confidence": 0.75,
            },
        ),
    ],
)
async def test_insert_if_not_exists_idempotent(
    db_session: AsyncSession,
    model_class: type,
    kwargs: dict,
) -> None:
    """Calling insert_if_not_exists twice with same (memory_id, enrichment_version) → one row."""
    from grove.enrichment.writers import insert_if_not_exists

    memory = await _seed_memory(db_session)
    enrichment_version = 1

    try:
        # First insert
        inserted_first = await insert_if_not_exists(
            db_session,
            model_class,
            memory_id=memory.id,
            enrichment_version=enrichment_version,
            **kwargs,
        )
        assert inserted_first is True, "First insert should return True (row created)"

        # Second insert — same (memory_id, enrichment_version) — must be a no-op
        inserted_second = await insert_if_not_exists(
            db_session,
            model_class,
            memory_id=memory.id,
            enrichment_version=enrichment_version,
            **kwargs,
        )
        assert inserted_second is False, "Second insert should return False (skipped)"

        # Exactly one row in the DB
        result = await db_session.execute(
            select(model_class).where(model_class.memory_id == memory.id)
        )
        rows = result.scalars().all()
        assert len(rows) == 1, f"Expected 1 row for {model_class.__name__}, found {len(rows)}"
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 2: Negative / re-enrichment — different enrichment_version is allowed
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "model_class,kwargs",
    [
        (
            Decision,
            {
                "decision_maker": "Alice",
                "context": "re-enrichment test",
                "options": ["X"],
                "chosen_option": "X",
                "rationale": "Updated rationale.",
                "outcome": None,
                "outcome_date": None,
                "confidence": 0.91,
            },
        ),
        (
            PeopleInteraction,
            {
                "person_name": "Eve",
                "interaction_medium": "slack",
                "topics": ["re-enrichment"],
                "next_steps": [],
                "confidence": 0.80,
            },
        ),
        (
            Task,
            {
                "description": "Re-enrichment task",
                "due_date": None,
                "status": "open",
                "related_people": [],
                "confidence": 0.70,
            },
        ),
        (
            Appointment,
            {
                "title": "Re-enrichment review",
                "starts_at": None,
                "ends_at": None,
                "location": None,
                "participants": [],
                "confidence": 0.72,
            },
        ),
    ],
)
async def test_different_enrichment_version_allowed(
    db_session: AsyncSession,
    model_class: type,
    kwargs: dict,
) -> None:
    """A row with a *different* enrichment_version for the same memory must be allowed.

    The unique constraint is (memory_id, enrichment_version), NOT just memory_id,
    so re-enrichment (bumping the version) must produce a second row.
    """
    from grove.enrichment.writers import insert_if_not_exists

    memory = await _seed_memory(db_session)

    try:
        # Version 1
        ok_v1 = await insert_if_not_exists(
            db_session,
            model_class,
            memory_id=memory.id,
            enrichment_version=1,
            **kwargs,
        )
        assert ok_v1 is True, "Version 1 insert should succeed"

        # Version 2 — must NOT be blocked by the constraint
        ok_v2 = await insert_if_not_exists(
            db_session,
            model_class,
            memory_id=memory.id,
            enrichment_version=2,
            **kwargs,
        )
        assert ok_v2 is True, (
            "Version 2 insert should succeed — constraint must not over-constrain re-enrichment"
        )

        # Two distinct rows must exist
        result = await db_session.execute(
            select(model_class).where(model_class.memory_id == memory.id)
        )
        rows = result.scalars().all()
        assert len(rows) == 2, (
            f"Expected 2 rows (one per version) for {model_class.__name__}, found {len(rows)}"
        )
        versions = {r.enrichment_version for r in rows}
        assert versions == {1, 2}, f"Expected versions {{1, 2}}, got {versions}"
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 3: Concurrency — concurrent inserts for same (memory_id, version) → one row
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "model_class,kwargs",
    [
        (
            Decision,
            {
                "decision_maker": "Alice",
                "context": "concurrency test",
                "options": ["A"],
                "chosen_option": "A",
                "rationale": "Concurrent.",
                "outcome": None,
                "outcome_date": None,
                "confidence": 0.9,
            },
        ),
        (
            PeopleInteraction,
            {
                "person_name": "Frank",
                "interaction_medium": "phone",
                "topics": ["sync"],
                "next_steps": [],
                "confidence": 0.82,
            },
        ),
        (
            Task,
            {
                "description": "Concurrent task",
                "due_date": None,
                "status": "open",
                "related_people": [],
                "confidence": 0.8,
            },
        ),
        (
            Appointment,
            {
                "title": "Concurrent meeting",
                "starts_at": None,
                "ends_at": None,
                "location": None,
                "participants": [],
                "confidence": 0.78,
            },
        ),
    ],
)
async def test_concurrent_inserts_produce_one_row(
    db_session: AsyncSession,
    model_class: type,
    kwargs: dict,
) -> None:
    """Concurrent coroutines inserting the same (memory_id, enrichment_version) must not raise.

    Both calls should complete without error; exactly one row should exist afterwards.
    This is the core guard against the double-claim scenario described in #201.
    Each concurrent call uses its own session (as the real workers do).
    """
    from grove.enrichment.writers import insert_if_not_exists

    memory = await _seed_memory(db_session)
    enrichment_version = 1

    async def _insert_in_own_session() -> bool:
        async with _Session() as s:
            result = await insert_if_not_exists(
                s,
                model_class,
                memory_id=memory.id,
                enrichment_version=enrichment_version,
                **kwargs,
            )
            return result

    try:
        results = await asyncio.gather(
            _insert_in_own_session(),
            _insert_in_own_session(),
            return_exceptions=False,
        )
        # Both calls must return a bool without raising.
        assert isinstance(results[0], bool), f"Expected bool, got {type(results[0])}"
        assert isinstance(results[1], bool), f"Expected bool, got {type(results[1])}"
        # Exactly one True (row created) and one False (skipped), in either order.
        assert sorted(results) == [False, True], f"Expected one True and one False, got {results}"

        # Exactly one row — confirm via the shared read session.
        result = await db_session.execute(
            select(model_class).where(model_class.memory_id == memory.id)
        )
        rows = result.scalars().all()
        assert len(rows) == 1, f"Concurrent inserts produced {len(rows)} rows; expected exactly 1"
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 4: Worker concurrency — no duplicate specialised-table rows after two
#         parallel writes claiming the same (memory_id, enrichment_version)
# ---------------------------------------------------------------------------


async def test_worker_concurrent_runs_no_duplicate_specialised_rows(
    db_session: AsyncSession,
) -> None:
    """Two parallel writers claiming the same memories must not produce duplicate rows.

    Simulates the double-claim scenario from #201: after the batch_session.commit()
    fix in run.py, two in-process coroutines can claim the same memory IDs. The
    upsert guard must ensure concurrent per-memory writes are idempotent — one row
    per (memory_id, enrichment_version), regardless of how many times the writer
    is invoked concurrently.

    Uses Decision rows as the representative specialised table.
    """
    from grove.enrichment.writers import insert_if_not_exists

    # Seed two memories.
    m1 = await _seed_memory(db_session)
    m2 = await _seed_memory(db_session)
    memory_ids = [m1.id, m2.id]

    async def _write_decision(memory_id: uuid.UUID) -> None:
        """Writer that inserts one Decision row, mirroring what #180's writers will do."""
        async with _Session() as s:
            await insert_if_not_exists(
                s,
                Decision,
                memory_id=memory_id,
                enrichment_version=1,
                decision_maker="stub",
                context="worker concurrency test",
                options=["A"],
                chosen_option="A",
                rationale="Concurrent stub.",
                outcome=None,
                outcome_date=None,
                confidence=0.9,
            )

    try:
        # Two concurrent "workers" both try to write the same memories.
        await asyncio.gather(
            _write_decision(m1.id),
            _write_decision(m1.id),
            _write_decision(m2.id),
            _write_decision(m2.id),
        )

        # Each memory should have exactly one Decision row.
        for mid in memory_ids:
            result = await db_session.execute(select(Decision).where(Decision.memory_id == mid))
            rows = result.scalars().all()
            assert len(rows) == 1, (
                f"memory {mid}: expected 1 Decision row after concurrent writes, found {len(rows)}"
            )
            # Confirm the row has the expected enrichment_version.
            assert rows[0].enrichment_version == 1, (
                f"memory {mid}: expected enrichment_version=1, got {rows[0].enrichment_version}"
            )
            assert rows[0].decision_maker == "stub", (
                f"memory {mid}: expected decision_maker='stub', got {rows[0].decision_maker!r}"
            )
    finally:
        for memory in (m1, m2):
            await _delete_memory(db_session, memory)
