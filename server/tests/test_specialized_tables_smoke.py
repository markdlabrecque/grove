"""Smoke tests for the V1 specialized enrichment tables.

Each test writes a row tied to a memory and confirms cascade-delete removes it.
Requires a real Postgres instance with migrations applied.
The DATABASE_URL env var is set by conftest.py (dev) or CI.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from grove.core.config import settings
from grove.models import Appointment, Decision, Memory, PeopleInteraction


@pytest.fixture
async def db_session():
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        yield session
    await engine.dispose()


@pytest.fixture
async def memory(db_session: AsyncSession) -> Memory:
    m = Memory(
        id=uuid.uuid4(),
        content="Decided to migrate the auth service to OAuth2 after evaluating three options.",
        client_id=uuid.uuid4(),
    )
    db_session.add(m)
    await db_session.commit()
    return m


async def test_decision_create_and_cascade_delete(db_session: AsyncSession, memory: Memory) -> None:
    decision = Decision(
        id=uuid.uuid4(),
        memory_id=memory.id,
        decision_maker="Mark",
        context="Auth service migration planning",
        options=["OAuth2", "SAML", "custom JWT"],
        chosen_option="OAuth2",
        rationale="Best ecosystem support and existing team familiarity.",
        outcome=None,
        outcome_date=None,
        confidence=0.92,
        enrichment_version=1,
    )
    db_session.add(decision)
    await db_session.commit()

    fetched = await db_session.get(Decision, decision.id)
    assert fetched is not None
    assert fetched.chosen_option == "OAuth2"
    assert fetched.options == ["OAuth2", "SAML", "custom JWT"]
    assert fetched.confidence == pytest.approx(0.92)
    assert fetched.enrichment_version == 1

    decision_id = decision.id
    await db_session.delete(memory)
    await db_session.commit()

    result = await db_session.execute(select(Decision).where(Decision.id == decision_id))
    assert result.scalar_one_or_none() is None


async def test_people_interaction_create_and_cascade_delete(
    db_session: AsyncSession, memory: Memory
) -> None:
    interaction = PeopleInteraction(
        id=uuid.uuid4(),
        memory_id=memory.id,
        person_name="Alice",
        interaction_medium="in-person",
        topics=["auth migration", "Q3 planning"],
        next_steps=["Send Alice the RFC draft", "Book follow-up for next week"],
        confidence=0.88,
        enrichment_version=1,
    )
    db_session.add(interaction)
    await db_session.commit()

    fetched = await db_session.get(PeopleInteraction, interaction.id)
    assert fetched is not None
    assert fetched.person_name == "Alice"
    assert fetched.interaction_medium == "in-person"
    assert fetched.topics == ["auth migration", "Q3 planning"]
    assert fetched.next_steps == ["Send Alice the RFC draft", "Book follow-up for next week"]
    assert fetched.confidence == pytest.approx(0.88)

    interaction_id = interaction.id
    await db_session.delete(memory)
    await db_session.commit()

    result = await db_session.execute(
        select(PeopleInteraction).where(PeopleInteraction.id == interaction_id)
    )
    assert result.scalar_one_or_none() is None


async def test_appointment_create_and_cascade_delete(
    db_session: AsyncSession, memory: Memory
) -> None:
    starts = datetime(2026, 6, 1, 14, 0, 0, tzinfo=UTC)
    ends = datetime(2026, 6, 1, 15, 0, 0, tzinfo=UTC)

    appointment = Appointment(
        id=uuid.uuid4(),
        memory_id=memory.id,
        title="Auth migration follow-up with Alice",
        starts_at=starts,
        ends_at=ends,
        location="Conference room B",
        participants=["Alice", "Mark"],
        confidence=0.80,
        enrichment_version=1,
    )
    db_session.add(appointment)
    await db_session.commit()

    fetched = await db_session.get(Appointment, appointment.id)
    assert fetched is not None
    assert fetched.title == "Auth migration follow-up with Alice"
    assert fetched.participants == ["Alice", "Mark"]
    assert fetched.starts_at == starts
    assert fetched.confidence == pytest.approx(0.80)

    appointment_id = appointment.id
    await db_session.delete(memory)
    await db_session.commit()

    result = await db_session.execute(select(Appointment).where(Appointment.id == appointment_id))
    assert result.scalar_one_or_none() is None
