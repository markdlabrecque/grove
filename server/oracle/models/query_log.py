from __future__ import annotations

import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import Boolean, ForeignKey, Integer, Text
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TIMESTAMP

from oracle.models.base import Base


class QueryLog(Base):
    __tablename__ = "query_logs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False, server_default="now()"
    )
    query_text: Mapped[str] = mapped_column(Text, nullable=False)
    query_embedding: Mapped[list[float] | None] = mapped_column(Vector(1536))
    tables_searched: Mapped[list[str]] = mapped_column(ARRAY(Text), nullable=False)
    result_count: Mapped[int] = mapped_column(Integer, nullable=False)
    # No FK constraint on returned_memory_ids — query logs survive memory
    # deletion by design (PRD §6.6). UUIDs may reference deleted memories.
    returned_memory_ids: Mapped[list[uuid.UUID] | None] = mapped_column(ARRAY(UUID(as_uuid=True)))
    synthesis_model: Mapped[str | None] = mapped_column(Text)
    synthesis_input_tokens: Mapped[int | None] = mapped_column(Integer)
    synthesis_output_tokens: Mapped[int | None] = mapped_column(Integer)
    user_feedback: Mapped[str | None] = mapped_column(Text)
    feedback_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    is_refinement: Mapped[bool | None] = mapped_column(Boolean, server_default="false")
    parent_query_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("query_logs.id"),
    )

    parent_query: Mapped[QueryLog | None] = relationship(
        "QueryLog", remote_side="QueryLog.id", back_populates="refinements"
    )
    refinements: Mapped[list[QueryLog]] = relationship("QueryLog", back_populates="parent_query")
