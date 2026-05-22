from __future__ import annotations

import time
import uuid
from datetime import datetime
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from grove.core.db import get_session
from grove.embeddings import WHOLE_VS_CHUNKS_THRESHOLD, chunk, count_tokens, get_embedding_provider
from grove.models.memory import Memory, MemoryChunk

logger = structlog.get_logger()

router = APIRouter()


class CaptureRequest(BaseModel):
    client_id: uuid.UUID
    content: str = Field(..., min_length=1)
    source_modality: str = Field(..., pattern=r"^(text|voice)$")
    source_device: str = Field(..., min_length=1)
    language: str = "en"
    captured_at: datetime

    # Persisted to DB for future use; no values are actively consumed server-side.
    # The "task" value from #474 is no longer sent by iOS (#482) and the
    # capture-time task-insert path has been removed (#487).
    client_intent: str | None = None

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
    # nullable: rows predating migration 0010 may have captured_at IS NULL
    captured_at: datetime | None
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
    total_start = time.monotonic()

    # --- Idempotency pre-check, embedding, and atomic DB write in one transaction ---
    # SQLAlchemy 2.x autobegin triggers on the first execute(), so the pre-check
    # and the subsequent session.begin() must share the same transaction block to
    # avoid "A transaction is already begun on this Session".
    memory_id = uuid.uuid4()
    async with session.begin():
        # Idempotency pre-check: must come before embedding so retries don't burn
        # API calls.
        existing_check = await session.execute(
            select(Memory).where(Memory.client_id == body.client_id)
        )
        existing_row = existing_check.scalar_one_or_none()
        if existing_row is not None:
            elapsed_ms = (time.monotonic() - total_start) * 1000
            logger.info(
                "capture_stored",
                client_id=str(body.client_id),
                memory_id=str(existing_row.id),
                content_length=len(body.content),
                idempotent=True,
                total_capture_latency_ms=round(elapsed_ms, 1),
            )
            response = CaptureResponse(
                id=existing_row.id,
                client_id=existing_row.client_id,
                captured_at=existing_row.captured_at,
                enriched=existing_row.enriched,
            )
            return JSONResponse(  # type: ignore[return-value]
                content=response.model_dump(mode="json"),
                status_code=status.HTTP_200_OK,
            )

        # --- Token count & embedding ---
        # The network call happens inside the transaction for simplicity. At
        # personal scale the extra lock hold is acceptable.
        token_count = count_tokens(body.content)
        provider = get_embedding_provider()

        embed_start = time.monotonic()
        try:
            if token_count <= WHOLE_VS_CHUNKS_THRESHOLD:
                vectors = await provider.embed_batch([body.content])
                whole_embedding: list[float] | None = vectors[0]
                chunk_texts: list[str] = []
                chunk_vectors: list[list[float]] = []
            else:
                chunk_texts = chunk(body.content)
                chunk_vectors = await provider.embed_batch(chunk_texts)
                whole_embedding = None
        except Exception as exc:
            logger.error("embedding_provider_error", error=str(exc))
            raise HTTPException(status_code=502, detail="Embedding provider error") from exc

        embedding_latency_ms = (time.monotonic() - embed_start) * 1000

        chunk_count = len(chunk_texts)

        stmt = (
            insert(Memory)
            .values(
                id=memory_id,
                client_id=body.client_id,
                content=body.content,
                source_modality=body.source_modality,
                source_device=body.source_device,
                language=body.language,
                captured_at=body.captured_at,
                client_intent=body.client_intent,
                enriched=False,
                embedding_model=provider.name,
                token_count=token_count,
                embedding=whole_embedding,
            )
            .on_conflict_do_nothing(index_elements=["client_id"])
            .returning(Memory)
        )
        result = await session.execute(stmt)
        row = result.scalar_one_or_none()

        if row is None:
            # Race: another request inserted the same client_id between our
            # pre-check and the INSERT.  Fetch and return the winning row.
            existing2 = await session.execute(
                select(Memory).where(Memory.client_id == body.client_id)
            )
            row = existing2.scalar_one()
        elif chunk_texts:
            # Insert chunk rows only when we actually did the chunked path.
            session.add_all(
                [
                    MemoryChunk(
                        id=uuid.uuid4(),
                        memory_id=row.id,
                        chunk_index=idx,
                        content=text,
                        embedding=vec,
                        embedding_model=provider.name,
                    )
                    for idx, (text, vec) in enumerate(zip(chunk_texts, chunk_vectors, strict=True))
                ]
            )

    total_elapsed_ms = (time.monotonic() - total_start) * 1000
    logger.info(
        "capture_stored",
        client_id=str(body.client_id),
        memory_id=str(row.id),
        content_length=len(body.content),
        token_count=token_count,
        chunk_count=chunk_count,
        embedding_latency_ms=round(embedding_latency_ms, 1),
        total_capture_latency_ms=round(total_elapsed_ms, 1),
        embedding_model=provider.name,
        idempotent=False,
    )

    return CaptureResponse(
        id=row.id,
        client_id=row.client_id,
        captured_at=row.captured_at,
        enriched=row.enriched,
    )
