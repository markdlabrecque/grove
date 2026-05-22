from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import TYPE_CHECKING

from sqlalchemy import Date, Float, ForeignKey, Index, Integer, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TIMESTAMP

from grove.models.base import Base

if TYPE_CHECKING:
    from grove.models.memory import Memory


class Task(Base):
    __tablename__ = "tasks"
    __table_args__ = (
        UniqueConstraint(
            "memory_id", "enrichment_version", name="uq_tasks_memory_id_enrichment_version"
        ),
        # Partial unique index: enforces at most one capture-time row per memory.
        # The composite constraint above cannot cover the NULL case because Postgres
        # treats every NULL as distinct in a standard unique index.
        Index(
            "uq_tasks_memory_id_capture_time",
            "memory_id",
            unique=True,
            postgresql_where="enrichment_version IS NULL",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    memory_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("memories.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    description: Mapped[str] = mapped_column(Text, nullable=False)
    due_date: Mapped[date | None] = mapped_column(Date, index=True)
    # V1: only 'open'; lifecycle management is deferred to a future review cycle.
    status: Mapped[str | None] = mapped_column(Text)
    related_people: Mapped[list[str] | None] = mapped_column(ARRAY(Text()))
    confidence: Mapped[float] = mapped_column(Float, nullable=False)
    # NULL when the row was created at capture time (before enrichment runs).
    # Stamped with PIPELINE_VERSION when the enrichment worker processes the memory.
    enrichment_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False, server_default="now()"
    )

    memory: Mapped[Memory] = relationship("Memory", back_populates="tasks")
