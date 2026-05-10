from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Float, ForeignKey, Integer, Text
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TIMESTAMP

from oracle.models.base import Base

if TYPE_CHECKING:
    from oracle.models.memory import Memory


class Appointment(Base):
    __tablename__ = "appointments"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    memory_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("memories.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    title: Mapped[str | None] = mapped_column(Text)
    # Best-effort LLM extraction; nullable when the memory doesn't specify a time.
    starts_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True), index=True)
    ends_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    location: Mapped[str | None] = mapped_column(Text)
    participants: Mapped[list[str] | None] = mapped_column(ARRAY(Text()))
    confidence: Mapped[float] = mapped_column(Float, nullable=False)
    enrichment_version: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False, server_default="now()"
    )

    memory: Mapped[Memory] = relationship("Memory", back_populates="appointments")
