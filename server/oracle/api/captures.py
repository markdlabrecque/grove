from __future__ import annotations

import time
import uuid
from datetime import datetime
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from oracle.core.db import get_session
from oracle.models.memory import Memory

logger = structlog.get_logger()

router = APIRouter()

_EMBEDDING_MODEL_SENTINEL = "text-embedding-3-small"


class CaptureRequest(BaseModel):
    client_id: uuid.UUID
    content: str = Field(..., min_length=1)
    source_modality: str = Field(..., pattern=r"^(text|voice)$")
    source_device: str = Field(..., min_length=1)
    language: str = "en"
    captured_at: datetime

    @field_validator("content")
    @classmethod
    def content_must_not_be_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("content must not be blank after stripping whitespace")
        return v

    @field_validator("captured_at")
    @classmethod
    def captured_at_must_be_tz_aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("captured_at must include timezone information (ISO 8601 with TZ)")
        return v


class CaptureResponse(BaseModel):
    id: uuid.UUID
    client_id: uuid.UUID
    captured_at: datetime
    enriched: bool


@router.post(
    "/captures",
    response_model=CaptureResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_capture(
    body: CaptureRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> CaptureResponse:
    start = time.monotonic()

    # INSERT … ON CONFLICT (client_id) DO NOTHING RETURNING *
    # If a row with this client_id already exists the INSERT silently no-ops
    # and returns no rows; we then fall through to the SELECT below.
    stmt = (
        insert(Memory)
        .values(
            id=uuid.uuid4(),
            client_id=body.client_id,
            content=body.content,
            source_modality=body.source_modality,
            source_device=body.source_device,
            language=body.language,
            captured_at=body.captured_at,
            enriched=False,
            embedding_model=_EMBEDDING_MODEL_SENTINEL,
            # embedding left NULL — filled in once the embeddings ticket lands
        )
        .on_conflict_do_nothing(index_elements=["client_id"])
        .returning(Memory)
    )

    result = await session.execute(stmt)
    row = result.scalar_one_or_none()

    if row is None:
        # Idempotent hit: the client_id already exists; fetch the original row.
        existing = await session.execute(select(Memory).where(Memory.client_id == body.client_id))
        row = existing.scalar_one()
        status_code = status.HTTP_200_OK
    else:
        status_code = status.HTTP_201_CREATED

    await session.commit()

    elapsed_ms = (time.monotonic() - start) * 1000
    logger.info(
        "capture_stored",
        client_id=str(body.client_id),
        memory_id=str(row.id),
        content_length=len(body.content),
        idempotent=(status_code == status.HTTP_200_OK),
        latency_ms=round(elapsed_ms, 1),
    )

    response = CaptureResponse(
        id=row.id,
        client_id=row.client_id,
        captured_at=row.captured_at,
        enriched=row.enriched,
    )

    # FastAPI uses the route's default status_code; we must override manually
    # when returning 200 on an idempotent hit. We do this by returning a
    # JSONResponse directly for the idempotent case.
    if status_code == status.HTTP_200_OK:
        from fastapi.responses import JSONResponse

        return JSONResponse(  # type: ignore[return-value]
            content=response.model_dump(mode="json"),
            status_code=status.HTTP_200_OK,
        )

    return response
