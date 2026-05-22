"""Integration tests for classify_and_write orchestrator (ticket #180).

TDD red commit: all tests in this file are expected to fail until the
classify_and_write function and per-table writers are implemented.

Coverage (per ticket #180 TDD completeness requirements):

1. Happy path — mixed-confidence classification:
   - Records with confidence >= 0.7 produce specialised rows with correct field values.
   - Records with confidence < 0.7 are dropped (no row written).
   - Memory ends enriched=True with enriched_version stamped.
   - enrichment_error is cleared to NULL.

2. Failure path — ClassificationError:
   - Memory stays enriched=False.
   - enrichment_error is set to the error message.
   - No specialised rows written.

3. Skipped path — SkippedReason raised:
   - Memory stays enriched=False.
   - enrichment_error is set.
   - No specialised rows written.

4. Atomicity — writer raises mid-transaction:
   - No specialised rows persist.
   - Memory stays enriched=False.
   - The per-memory transaction is fully rolled back.

5. Idempotence — calling classify_and_write twice on same memory/version:
   - No duplicate rows.
   - No error on second call.

6. Version stamping — enriched_version matches PIPELINE_VERSION.

Requires a real Postgres+pgvector instance (DATABASE_URL from conftest / env).
HTTP boundary (OpenRouter) is mocked throughout.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.enrichment.classifier import ClassificationError, SkippedReason
from grove.enrichment.schemas import (
    Appointment,
    Classification,
    Decision,
    PeopleInteraction,
)
from grove.models import (
    Appointment as AppointmentModel,
)
from grove.models import (
    Decision as DecisionModel,
)
from grove.models import (
    Memory,
)
from grove.models import (
    PeopleInteraction as PeopleInteractionModel,
)

_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_Session = async_sessionmaker(_engine, expire_on_commit=False)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_memory() -> Memory:
    return Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Discussed budget with Alice. Decided to go with Option A.",
        token_count=20,
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


def _make_mixed_classification() -> Classification:
    """Return a Classification with one accepted and one dropped record per type."""
    return Classification(
        decisions=[
            Decision(
                decision_maker="Alice",
                context="Budget discussion",
                options=["Option A", "Option B"],
                chosen_option="Option A",
                rationale="Best value",
                outcome=None,
                outcome_date=None,
                confidence=0.85,  # >= 0.7 — accepted
            ),
            Decision(
                decision_maker="Bob",
                context="Low-confidence guess",
                options=None,
                chosen_option=None,
                rationale=None,
                outcome=None,
                outcome_date=None,
                confidence=0.50,  # < 0.7 — dropped
            ),
        ],
        people_interactions=[
            PeopleInteraction(
                person_name="Alice",
                interaction_medium="meeting",
                topics=["budget"],
                next_steps=["follow up"],
                confidence=0.90,  # >= 0.7 — accepted
            ),
            PeopleInteraction(
                person_name="Unknown",
                interaction_medium=None,
                topics=None,
                next_steps=None,
                confidence=0.30,  # < 0.7 — dropped
            ),
        ],
        appointments=[
            Appointment(
                title="Budget review",
                starts_at=None,
                ends_at=None,
                location="Zoom",
                participants=["Alice", "Bob"],
                confidence=0.80,  # >= 0.7 — accepted
            ),
            Appointment(
                title="Vague meeting",
                starts_at=None,
                ends_at=None,
                location=None,
                participants=None,
                confidence=0.20,  # < 0.7 — dropped
            ),
        ],
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _Session() as session:
        yield session


@pytest.fixture(autouse=True)
def stub_check_spend_cap():  # type: ignore[return]
    """No-op the spend cap check for all tests in this file.

    test_classify_and_write.py exercises orchestrator logic only.
    Spend cap enforcement is covered in test_spend_cap.py.
    Bypassing it here avoids asyncpg "another operation is in progress"
    errors that arise when check_spend_cap opens a second connection on
    the same NullPool engine while the test's session has one already open.
    """
    with patch(
        "grove.enrichment.orchestrator.check_spend_cap",
        new_callable=AsyncMock,
        return_value=None,
    ):
        yield


# ---------------------------------------------------------------------------
# Test 1: Happy path — mixed confidence classification
# ---------------------------------------------------------------------------


async def test_classify_and_write_happy_path(db_session: AsyncSession) -> None:
    """Accepted records (>= 0.7) are written; dropped records (< 0.7) are not.

    Memory ends enriched=True with enriched_version stamped, enrichment_error NULL.
    """
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.run import PIPELINE_VERSION

    memory = await _seed_memory(db_session)

    classification = _make_mixed_classification()
    mock_result = ClassificationResult(
        classification=classification,
        prompt_tokens=100,
        completion_tokens=50,
        total_tokens=150,
        cost_usd=0.001,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    try:
        # --- Memory state ---
        await db_session.refresh(memory)
        assert memory.enriched is True
        assert memory.enriched_at is not None
        assert memory.enriched_version == PIPELINE_VERSION
        assert memory.enrichment_error is None

        # --- Accepted Decision row ---
        result = await db_session.execute(
            select(DecisionModel).where(DecisionModel.memory_id == memory.id)
        )
        decisions = result.scalars().all()
        assert len(decisions) == 1, f"Expected 1 Decision row (accepted only), got {len(decisions)}"
        assert decisions[0].decision_maker == "Alice"
        assert decisions[0].context == "Budget discussion"
        assert decisions[0].chosen_option == "Option A"
        assert decisions[0].confidence == 0.85
        assert decisions[0].enrichment_version == PIPELINE_VERSION

        # --- Accepted PeopleInteraction row ---
        result = await db_session.execute(
            select(PeopleInteractionModel).where(PeopleInteractionModel.memory_id == memory.id)
        )
        interactions = result.scalars().all()
        assert len(interactions) == 1, f"Expected 1 PeopleInteraction row, got {len(interactions)}"
        assert interactions[0].person_name == "Alice"
        assert interactions[0].interaction_medium == "meeting"
        assert interactions[0].topics == ["budget"]
        assert interactions[0].confidence == 0.90
        assert interactions[0].enrichment_version == PIPELINE_VERSION

        # --- Accepted Appointment row ---
        result = await db_session.execute(
            select(AppointmentModel).where(AppointmentModel.memory_id == memory.id)
        )
        appointments = result.scalars().all()
        assert len(appointments) == 1, f"Expected 1 Appointment row, got {len(appointments)}"
        assert appointments[0].title == "Budget review"
        assert appointments[0].location == "Zoom"
        assert appointments[0].confidence == 0.80
        assert appointments[0].enrichment_version == PIPELINE_VERSION

    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 2: Failure path — ClassificationError
# ---------------------------------------------------------------------------


async def test_classify_and_write_classification_error(db_session: AsyncSession) -> None:
    """When classify_memory raises ClassificationError, memory stays unenriched.

    enrichment_error is set to the error message string; no specialised rows are written.
    """
    from grove.enrichment.orchestrator import classify_and_write

    memory = await _seed_memory(db_session)
    error_msg = "Model returned non-JSON content: 'garbled'"

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        side_effect=ClassificationError(error_msg),
    ):
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    try:
        await db_session.refresh(memory)
        assert memory.enriched is False
        assert memory.enrichment_error == error_msg

        # No specialised rows written
        for model_class in (DecisionModel, PeopleInteractionModel, AppointmentModel):
            result = await db_session.execute(
                select(model_class).where(model_class.memory_id == memory.id)
            )
            rows = result.scalars().all()
            assert len(rows) == 0, (
                f"Expected 0 {model_class.__name__} rows after ClassificationError, got {len(rows)}"
            )
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 3: Skipped path — SkippedReason
# ---------------------------------------------------------------------------


async def test_classify_and_write_skipped_reason(db_session: AsyncSession) -> None:
    """When classify_memory returns SkippedReason, memory stays unenriched.

    enrichment_error is set; no specialised rows are written.
    """
    from grove.enrichment.orchestrator import classify_and_write

    memory = await _seed_memory(db_session)

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=SkippedReason.TOO_LARGE,
    ):
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    try:
        await db_session.refresh(memory)
        assert memory.enriched is False
        assert memory.enrichment_error == SkippedReason.TOO_LARGE

        # No specialised rows written
        for model_class in (DecisionModel, PeopleInteractionModel, AppointmentModel):
            result = await db_session.execute(
                select(model_class).where(model_class.memory_id == memory.id)
            )
            rows = result.scalars().all()
            assert len(rows) == 0, (
                f"Expected 0 {model_class.__name__} rows after SkippedReason, got {len(rows)}"
            )
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 4: Atomicity — writer raises mid-transaction
# ---------------------------------------------------------------------------


async def test_classify_and_write_atomicity_on_writer_failure(db_session: AsyncSession) -> None:
    """If a writer raises, no specialised rows persist and memory stays unenriched.

    This is the most important test — it pins the 'same transaction' guarantee.
    We inject a failure by patching insert_if_not_exists to raise on the second
    call (after the first Decision row is pending but before commit), then assert
    full rollback.
    """
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write

    memory = await _seed_memory(db_session)

    # Classification with one item per type — all above threshold.
    classification = Classification(
        decisions=[
            Decision(
                decision_maker="Alice",
                context="Atomicity test",
                options=["A"],
                chosen_option="A",
                rationale="Test",
                outcome=None,
                outcome_date=None,
                confidence=0.9,
            )
        ],
        people_interactions=[
            PeopleInteraction(
                person_name="Alice",
                interaction_medium="email",
                topics=["test"],
                next_steps=None,
                confidence=0.85,
            )
        ],
        appointments=[],
    )
    mock_result = ClassificationResult(
        classification=classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=None,
    )

    call_count = 0

    async def _failing_insert(session: AsyncSession, model_class: type, **kwargs: object) -> bool:
        nonlocal call_count
        call_count += 1
        if call_count == 2:
            raise RuntimeError("Injected writer failure on second call")
        # Execute the upsert without committing so the first insert is pending
        # (not yet committed) when the second call raises.  The orchestrator's
        # except block then rolls back the whole transaction.

        from sqlalchemy import inspect as _inspect
        from sqlalchemy.dialects.postgresql import insert as _pg_insert

        table = _inspect(model_class).persist_selectable
        constraint_name = f"uq_{table.name}_memory_id_enrichment_version"
        stmt = (
            _pg_insert(model_class)
            .values(**kwargs)
            .on_conflict_do_nothing(constraint=constraint_name)
            .returning(table.c.id)
        )
        result = await session.execute(stmt)
        return result.fetchone() is not None

    with (
        patch(
            "grove.enrichment.orchestrator.classify_memory",
            new_callable=AsyncMock,
            return_value=mock_result,
        ),
        patch(
            "grove.enrichment.orchestrator.insert_if_not_exists",
            side_effect=_failing_insert,
        ),
    ):
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    try:
        await db_session.refresh(memory)
        # Memory must stay unenriched — the transaction was rolled back.
        assert memory.enriched is False, "Memory should remain unenriched after writer failure"
        assert memory.enrichment_error is not None, (
            "enrichment_error should be set after writer failure"
        )

        # No specialised rows — full rollback.
        for model_class in (DecisionModel, PeopleInteractionModel, AppointmentModel):
            result = await db_session.execute(
                select(model_class).where(model_class.memory_id == memory.id)
            )
            rows = result.scalars().all()
            assert len(rows) == 0, (
                f"Expected 0 {model_class.__name__} rows after rolled-back transaction, "
                f"got {len(rows)}"
            )
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 5: Idempotence — second call is a safe no-op
# ---------------------------------------------------------------------------


async def test_classify_and_write_idempotent(db_session: AsyncSession) -> None:
    """Running classify_and_write twice on the same memory/version produces no duplicates.

    The upsert helper (insert_if_not_exists, ON CONFLICT DO NOTHING) handles this.
    Second call must not raise and must not produce duplicate rows.
    """
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.run import PIPELINE_VERSION

    memory = await _seed_memory(db_session)

    classification = Classification(
        decisions=[
            Decision(
                decision_maker="Alice",
                context="Idempotence test",
                options=["A"],
                chosen_option="A",
                rationale="Test",
                outcome=None,
                outcome_date=None,
                confidence=0.9,
            )
        ],
        people_interactions=[],
        appointments=[],
    )
    mock_result = ClassificationResult(
        classification=classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=None,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        # First call
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

        # Second call — memory is now enriched=True; should be a no-op, no error.
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    try:
        await db_session.refresh(memory)
        assert memory.enriched is True
        assert memory.enriched_version == PIPELINE_VERSION

        # Exactly one Decision row — no duplicates from the second call.
        result = await db_session.execute(
            select(DecisionModel).where(DecisionModel.memory_id == memory.id)
        )
        decisions = result.scalars().all()
        assert len(decisions) == 1, f"Expected 1 Decision row after two calls, got {len(decisions)}"
        assert decisions[0].decision_maker == "Alice"
    finally:
        await _delete_memory(db_session, memory)


# ---------------------------------------------------------------------------
# Test 6: Version stamping
# ---------------------------------------------------------------------------


async def test_classify_and_write_version_stamping(db_session: AsyncSession) -> None:
    """enriched_version on memory and on specialised rows must equal PIPELINE_VERSION."""
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.run import PIPELINE_VERSION

    memory = await _seed_memory(db_session)

    classification = Classification(
        decisions=[],
        people_interactions=[
            PeopleInteraction(
                person_name="Carol",
                interaction_medium="slack",
                topics=["version check"],
                next_steps=None,
                confidence=0.88,
            )
        ],
        appointments=[],
    )
    mock_result = ClassificationResult(
        classification=classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=None,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        async with _Session() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    try:
        await db_session.refresh(memory)
        assert memory.enriched_version == PIPELINE_VERSION, (
            f"Memory enriched_version={memory.enriched_version!r}, expected {PIPELINE_VERSION}"
        )

        result = await db_session.execute(
            select(PeopleInteractionModel).where(PeopleInteractionModel.memory_id == memory.id)
        )
        interactions = result.scalars().all()
        assert len(interactions) == 1
        assert interactions[0].enrichment_version == PIPELINE_VERSION, (
            f"PeopleInteraction enrichment_version={interactions[0].enrichment_version!r}, "
            f"expected {PIPELINE_VERSION}"
        )
    finally:
        await _delete_memory(db_session, memory)
