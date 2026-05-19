from __future__ import annotations

import base64
import json
import uuid
from datetime import date, datetime
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from grove.core.db import get_session
from grove.models.memory import Memory

logger = structlog.get_logger()

router = APIRouter()


# ---------------------------------------------------------------------------
# Response schemas — no embedding columns exposed
# ---------------------------------------------------------------------------


class ChunkSchema(BaseModel):
    id: uuid.UUID
    memory_id: uuid.UUID
    chunk_index: int
    content: str
    embedding_model: str

    model_config = {"from_attributes": True}


class DecisionSchema(BaseModel):
    id: uuid.UUID
    memory_id: uuid.UUID
    decision_maker: str | None
    context: str | None
    options: list[str] | None
    chosen_option: str | None
    rationale: str | None
    outcome: str | None
    outcome_date: date | None
    confidence: float
    enrichment_version: int
    created_at: datetime

    model_config = {"from_attributes": True}


class PeopleInteractionSchema(BaseModel):
    id: uuid.UUID
    memory_id: uuid.UUID
    person_name: str
    interaction_medium: str | None
    topics: list[str] | None
    next_steps: list[str] | None
    confidence: float
    enrichment_version: int
    created_at: datetime

    model_config = {"from_attributes": True}


class TaskSchema(BaseModel):
    id: uuid.UUID
    memory_id: uuid.UUID
    description: str
    due_date: date | None
    status: str | None
    related_people: list[str] | None
    confidence: float
    enrichment_version: int
    created_at: datetime
    eventkit_identifier: str | None
    eventkit_linked_at: datetime | None

    model_config = {"from_attributes": True}


class AppointmentSchema(BaseModel):
    id: uuid.UUID
    memory_id: uuid.UUID
    title: str | None
    starts_at: datetime | None
    ends_at: datetime | None
    location: str | None
    participants: list[str] | None
    confidence: float
    enrichment_version: int
    created_at: datetime

    model_config = {"from_attributes": True}


class MemoryDetailSchema(BaseModel):
    id: uuid.UUID
    client_id: uuid.UUID
    content: str
    created_at: datetime
    captured_at: datetime | None
    source_modality: str | None
    source_device: str | None
    language: str | None
    token_count: int | None
    embedding_model: str | None
    enriched: bool
    enriched_at: datetime | None
    enriched_version: int | None
    enrichment_error: str | None
    chunks: list[ChunkSchema]
    decisions: list[DecisionSchema]
    people_interactions: list[PeopleInteractionSchema]
    tasks: list[TaskSchema]
    appointments: list[AppointmentSchema]

    model_config = {"from_attributes": True}


class MemorySummarySchema(BaseModel):
    """Lightweight summary returned by the list endpoint.

    Omits full content, embedding, enrichment_error, and all related collections
    to keep list responses small. Use GET /v1/memories/{id} for the full record.
    """

    id: uuid.UUID
    client_id: uuid.UUID
    captured_at: datetime | None
    created_at: datetime
    enriched: bool
    language: str | None
    source_modality: str | None
    content_preview: str  # first 140 chars of content

    model_config = {"from_attributes": True}


class MemoryListResponse(BaseModel):
    items: list[MemorySummarySchema]
    next_cursor: str | None


# ---------------------------------------------------------------------------
# Cursor helpers
#
# Cursor format: base64(json({"created_at": <iso>, "id": <uuid>}))
# Clients must treat this as opaque. The implementation uses a composite
# WHERE (created_at, id) < (cursor.created_at, cursor.id) which stays stable
# even when rows are deleted between pages.
# ---------------------------------------------------------------------------


def _encode_cursor(created_at: datetime, memory_id: uuid.UUID) -> str:
    payload = json.dumps({"created_at": created_at.isoformat(), "id": str(memory_id)})
    return base64.urlsafe_b64encode(payload.encode()).decode()


def _decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        payload = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
        cur_created_at = datetime.fromisoformat(payload["created_at"])
        cur_id = uuid.UUID(payload["id"])
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="invalid cursor",
        ) from exc
    return cur_created_at, cur_id


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.get(
    "/memories",
    response_model=MemoryListResponse,
    status_code=status.HTTP_200_OK,
)
async def list_memories(
    session: Annotated[AsyncSession, Depends(get_session)],
    created_after: Annotated[datetime | None, Query()] = None,
    created_before: Annotated[datetime | None, Query()] = None,
    enriched: Annotated[bool | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    cursor: Annotated[str | None, Query()] = None,
) -> MemoryListResponse:
    """List memories in reverse chronological order (created_at DESC, id DESC).

    Pagination uses an opaque base64 cursor. Pass the returned `next_cursor`
    value as the `cursor` query parameter on the next request. The cursor
    encodes `{"created_at": <iso>, "id": <uuid>}` and is stable across deletes.

    Summary fields only — no content, embedding, or related collections.
    Use GET /v1/memories/{id} for the full record.
    """
    stmt = select(Memory).order_by(Memory.created_at.desc(), Memory.id.desc()).limit(limit + 1)

    if created_after is not None:
        stmt = stmt.where(Memory.created_at > created_after)
    if created_before is not None:
        stmt = stmt.where(Memory.created_at < created_before)
    if enriched is not None:
        stmt = stmt.where(Memory.enriched == enriched)
    if cursor is not None:
        cur_created_at, cur_id = _decode_cursor(cursor)
        # Composite keyset pagination: rows strictly before the cursor position.
        stmt = stmt.where(
            (Memory.created_at < cur_created_at)
            | ((Memory.created_at == cur_created_at) & (Memory.id < cur_id))
        )

    result = await session.execute(stmt)
    rows = list(result.scalars().all())

    has_next = len(rows) > limit
    page = rows[:limit]

    next_cursor: str | None = None
    if has_next and page:
        last = page[-1]
        next_cursor = _encode_cursor(last.created_at, last.id)

    items = [
        MemorySummarySchema(
            id=m.id,
            client_id=m.client_id,
            captured_at=m.captured_at,
            created_at=m.created_at,
            enriched=m.enriched,
            language=m.language,
            source_modality=m.source_modality,
            content_preview=m.content[:140],
        )
        for m in page
    ]

    logger.info("memories_listed", count=len(items), has_next=has_next)

    return MemoryListResponse(items=items, next_cursor=next_cursor)


@router.delete(
    "/memories/{memory_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_memory(
    memory_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> None:
    """Delete a memory and cascade to all related rows.

    Cascade covers: memory_chunks, decisions, people_interactions, tasks,
    appointments — via SQLAlchemy ORM "all, delete-orphan" which triggers the
    DB-level ON DELETE CASCADE FKs on those tables.

    query_logs rows that reference this memory via returned_memory_ids are NOT
    touched: that column is an ARRAY(UUID) with no FK constraint by design
    (PRD §6.6). The audit trail survives deletion; stale UUIDs remain in the
    array unchanged.
    """
    memory = await session.get(Memory, memory_id)
    if memory is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="memory not found")

    await session.delete(memory)
    await session.commit()

    logger.info("memory_deleted", memory_id=str(memory_id))


@router.get(
    "/memories/{memory_id}",
    response_model=MemoryDetailSchema,
    status_code=status.HTTP_200_OK,
)
async def get_memory(
    memory_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> MemoryDetailSchema:
    stmt = (
        select(Memory)
        .where(Memory.id == memory_id)
        .options(
            selectinload(Memory.chunks),
            selectinload(Memory.decisions),
            selectinload(Memory.people_interactions),
            selectinload(Memory.tasks),
            selectinload(Memory.appointments),
        )
    )

    result = await session.execute(stmt)
    memory = result.scalar_one_or_none()

    if memory is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="memory not found")

    logger.info(
        "memory_fetched",
        memory_id=str(memory_id),
        chunk_count=len(memory.chunks),
        decision_count=len(memory.decisions),
        people_interaction_count=len(memory.people_interactions),
        task_count=len(memory.tasks),
        appointment_count=len(memory.appointments),
    )

    return MemoryDetailSchema(
        id=memory.id,
        client_id=memory.client_id,
        content=memory.content,
        created_at=memory.created_at,
        captured_at=memory.captured_at,
        source_modality=memory.source_modality,
        source_device=memory.source_device,
        language=memory.language,
        token_count=memory.token_count,
        embedding_model=memory.embedding_model,
        enriched=memory.enriched,
        enriched_at=memory.enriched_at,
        enriched_version=memory.enriched_version,
        enrichment_error=memory.enrichment_error,
        chunks=[ChunkSchema.model_validate(c) for c in memory.chunks],
        decisions=[DecisionSchema.model_validate(d) for d in memory.decisions],
        people_interactions=[
            PeopleInteractionSchema.model_validate(p) for p in memory.people_interactions
        ],
        tasks=[TaskSchema.model_validate(t) for t in memory.tasks],
        appointments=[AppointmentSchema.model_validate(a) for a in memory.appointments],
    )
