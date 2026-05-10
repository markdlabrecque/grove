"""Smoke tests for Memory and MemoryChunk models.

Requires a real Postgres+pgvector instance with migrations applied.
The DATABASE_URL env var is set by conftest.py (dev) or CI.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from oracle.core.config import settings
from oracle.models import Memory, MemoryChunk


@pytest.fixture
async def db_session():
    engine = create_async_engine(settings.database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as session:
        yield session
    await engine.dispose()


async def test_create_and_fetch_memory(db_session: AsyncSession) -> None:
    client_id = uuid.uuid4()
    memory = Memory(
        id=uuid.uuid4(),
        content="Test memory content for smoke test.",
        client_id=client_id,
    )
    db_session.add(memory)
    await db_session.commit()

    fetched = await db_session.get(Memory, memory.id)
    assert fetched is not None
    assert fetched.content == "Test memory content for smoke test."
    assert fetched.enriched is False
    assert fetched.client_id == client_id

    # Cleanup
    await db_session.delete(fetched)
    await db_session.commit()


async def test_cascade_delete_removes_chunks(db_session: AsyncSession) -> None:
    memory = Memory(
        id=uuid.uuid4(),
        content="Long memory that was chunked.",
        client_id=uuid.uuid4(),
    )
    db_session.add(memory)
    await db_session.flush()

    # Fake 1536-dim embedding (all zeros is valid for storage; not for search).
    fake_embedding = [0.0] * 1536

    chunk_a = MemoryChunk(
        id=uuid.uuid4(),
        memory_id=memory.id,
        chunk_index=0,
        content="First chunk.",
        embedding=fake_embedding,
        embedding_model="text-embedding-3-small",
    )
    chunk_b = MemoryChunk(
        id=uuid.uuid4(),
        memory_id=memory.id,
        chunk_index=1,
        content="Second chunk.",
        embedding=fake_embedding,
        embedding_model="text-embedding-3-small",
    )
    db_session.add_all([chunk_a, chunk_b])
    await db_session.commit()

    memory_id = memory.id
    chunk_ids = [chunk_a.id, chunk_b.id]

    # Deleting the memory should cascade to chunks.
    await db_session.delete(memory)
    await db_session.commit()

    # Memory gone.
    assert await db_session.get(Memory, memory_id) is None

    # Chunks gone.
    result = await db_session.execute(select(MemoryChunk).where(MemoryChunk.id.in_(chunk_ids)))
    assert result.scalars().all() == []
