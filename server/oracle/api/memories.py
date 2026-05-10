from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from oracle.core.db import get_session
from oracle.models.memory import Memory

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


# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------


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

    # Sort chunks by index; other collections have no ordering requirement.
    sorted_chunks = sorted(memory.chunks, key=lambda c: c.chunk_index)

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
        chunks=[ChunkSchema.model_validate(c) for c in sorted_chunks],
        decisions=[DecisionSchema.model_validate(d) for d in memory.decisions],
        people_interactions=[
            PeopleInteractionSchema.model_validate(p) for p in memory.people_interactions
        ],
        tasks=[TaskSchema.model_validate(t) for t in memory.tasks],
        appointments=[AppointmentSchema.model_validate(a) for a in memory.appointments],
    )
