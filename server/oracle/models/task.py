from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import TYPE_CHECKING

from sqlalchemy import Date, Float, ForeignKey, Integer, Text
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TIMESTAMP

from oracle.models.base import Base

if TYPE_CHECKING:
    from oracle.models.memory import Memory


class Task(Base):
    __tablename__ = "tasks"

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
    enrichment_version: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False, server_default="now()"
    )

    memory: Mapped[Memory] = relationship("Memory", back_populates="tasks")
