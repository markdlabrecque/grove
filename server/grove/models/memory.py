from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    Boolean,
    ForeignKey,
    Integer,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TIMESTAMP

from grove.models.base import Base

if TYPE_CHECKING:
    from grove.models.appointment import Appointment
    from grove.models.decision import Decision
    from grove.models.people_interaction import PeopleInteraction
    from grove.models.task import Task


class Memory(Base):
    __tablename__ = "memories"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False, server_default="now()"
    )
    # Client-supplied timestamp — the moment the user captured the memory on-device.
    # Distinct from created_at (server ingestion time); nullable to allow old rows.
    captured_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    source_modality: Mapped[str | None] = mapped_column(Text)
    source_device: Mapped[str | None] = mapped_column(Text)
    language: Mapped[str | None] = mapped_column(Text)
    token_count: Mapped[int | None] = mapped_column(Integer)
    embedding_model: Mapped[str | None] = mapped_column(Text)
    # Null when content is chunked (long memories stored in memory_chunks instead).
    embedding: Mapped[list[float] | None] = mapped_column(Vector(1536))
    client_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, unique=True)
    enriched: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default="false")
    enriched_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    enriched_version: Mapped[int | None] = mapped_column(Integer)
    enrichment_error: Mapped[str | None] = mapped_column(Text)
    # Client-supplied intent set at capture time. V1 value: "task". Nullable
    # (no intent signal) for all other captures. Kept loose — no CHECK
    # constraint — so future intent values require no schema change.
    client_intent: Mapped[str | None] = mapped_column(Text)

    chunks: Mapped[list[MemoryChunk]] = relationship(
        "MemoryChunk",
        back_populates="memory",
        cascade="all, delete-orphan",
        order_by="MemoryChunk.chunk_index",
    )
    decisions: Mapped[list[Decision]] = relationship(
        "Decision", back_populates="memory", cascade="all, delete-orphan"
    )
    people_interactions: Mapped[list[PeopleInteraction]] = relationship(
        "PeopleInteraction", back_populates="memory", cascade="all, delete-orphan"
    )
    tasks: Mapped[list[Task]] = relationship(
        "Task", back_populates="memory", cascade="all, delete-orphan"
    )
    appointments: Mapped[list[Appointment]] = relationship(
        "Appointment", back_populates="memory", cascade="all, delete-orphan"
    )


class MemoryChunk(Base):
    __tablename__ = "memory_chunks"

    __table_args__ = (UniqueConstraint("memory_id", "chunk_index", name="uq_memory_chunk_index"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    memory_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("memories.id", ondelete="CASCADE"),
        nullable=False,
    )
    chunk_index: Mapped[int] = mapped_column(Integer, nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    embedding: Mapped[list[float]] = mapped_column(Vector(1536), nullable=False)
    embedding_model: Mapped[str] = mapped_column(Text, nullable=False)

    memory: Mapped[Memory] = relationship("Memory", back_populates="chunks")
