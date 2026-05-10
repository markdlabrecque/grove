from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Integer, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.types import TIMESTAMP

from oracle.models.base import Base


class EnrichmentState(Base):
    __tablename__ = "enrichment_state"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    run_started_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
    run_completed_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    # Correlates with Memory.enriched_version to identify which pipeline run processed a memory.
    pipeline_version: Mapped[int] = mapped_column(Integer, nullable=False)
    memories_processed: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0")
    classifications_created: Mapped[int] = mapped_column(
        Integer, nullable=False, server_default="0"
    )
    errors: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0")
    notes: Mapped[str | None] = mapped_column(Text)
