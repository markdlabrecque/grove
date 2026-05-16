"""Smoke tests for QueryLog and EnrichmentState models.

Requires a real Postgres+pgvector instance with migrations applied.
The DATABASE_URL env var is set by conftest.py (dev) or CI.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from grove.core.config import settings
from grove.models import EnrichmentState, QueryLog


@pytest.fixture
async def db_session():
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        yield session
    await engine.dispose()


async def test_create_and_fetch_query_log(db_session: AsyncSession) -> None:
    log = QueryLog(
        id=uuid.uuid4(),
        query_text="What decisions did I make about the project last month?",
        tables_searched=["memories"],
        result_count=3,
        returned_memory_ids=[uuid.uuid4(), uuid.uuid4()],
    )
    db_session.add(log)
    await db_session.commit()

    fetched = await db_session.get(QueryLog, log.id)
    assert fetched is not None
    assert fetched.query_text == "What decisions did I make about the project last month?"
    assert fetched.tables_searched == ["memories"]
    assert fetched.result_count == 3
    assert len(fetched.returned_memory_ids) == 2
    assert fetched.is_refinement is False
    assert fetched.parent_query_id is None

    await db_session.delete(fetched)
    await db_session.commit()


async def test_query_log_self_fk_refinement(db_session: AsyncSession) -> None:
    parent = QueryLog(
        id=uuid.uuid4(),
        query_text="What projects am I working on?",
        tables_searched=["memories"],
        result_count=5,
    )
    db_session.add(parent)
    await db_session.flush()

    child = QueryLog(
        id=uuid.uuid4(),
        query_text="What projects am I working on in Q2?",
        tables_searched=["memories"],
        result_count=2,
        is_refinement=True,
        parent_query_id=parent.id,
    )
    db_session.add(child)
    await db_session.commit()

    fetched_child = await db_session.get(QueryLog, child.id)
    assert fetched_child is not None
    assert fetched_child.parent_query_id == parent.id

    # Cleanup in FK-safe order.
    await db_session.delete(fetched_child)
    await db_session.flush()
    fetched_parent = await db_session.get(QueryLog, parent.id)
    await db_session.delete(fetched_parent)
    await db_session.commit()


async def test_create_and_fetch_enrichment_state(db_session: AsyncSession) -> None:
    run = EnrichmentState(
        id=uuid.uuid4(),
        run_started_at=datetime.now(tz=UTC),
        pipeline_version=1,
        memories_processed=42,
        classifications_created=10,
        errors=2,
        notes="First enrichment run.",
    )
    db_session.add(run)
    await db_session.commit()

    fetched = await db_session.get(EnrichmentState, run.id)
    assert fetched is not None
    assert fetched.pipeline_version == 1
    assert fetched.memories_processed == 42
    assert fetched.classifications_created == 10
    assert fetched.errors == 2
    assert fetched.notes == "First enrichment run."
    assert fetched.run_completed_at is None

    await db_session.delete(fetched)
    await db_session.commit()


async def test_enrichment_state_defaults(db_session: AsyncSession) -> None:
    run = EnrichmentState(
        id=uuid.uuid4(),
        run_started_at=datetime.now(tz=UTC),
        pipeline_version=2,
    )
    db_session.add(run)
    await db_session.commit()

    result = await db_session.execute(select(EnrichmentState).where(EnrichmentState.id == run.id))
    fetched = result.scalar_one()
    assert fetched.memories_processed == 0
    assert fetched.classifications_created == 0
    assert fetched.errors == 0

    await db_session.delete(fetched)
    await db_session.commit()
