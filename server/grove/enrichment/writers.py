"""Idempotent specialised-table writer helpers (ticket #201).

The enrichment worker commits the batch-session lock before the per-memory
loop, which means two concurrent in-process workers can claim the same memory
IDs. This module provides insert_if_not_exists — an ON CONFLICT DO NOTHING
upsert that makes every specialised-table write safe to call multiple times for
the same (memory_id, enrichment_version) pair.

Note: `grove.enrichment.orchestrator` carries a near-identical non-committing
variant of `insert_if_not_exists`. The orchestrator path needs the caller
(`classify_and_write`) to own the transaction boundary so that all four
specialised-table inserts + the `memory.enriched=True` flip happen atomically;
this module's version commits per call and is currently used only by the
upsert idempotency test suite. The two should be unified if a future change
gives both call sites the same transaction semantics.
"""

from __future__ import annotations

import uuid
from typing import Any

import structlog
from sqlalchemy import inspect
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from grove.models.base import Base

logger = structlog.get_logger(__name__)


async def insert_if_not_exists(
    session: AsyncSession,
    model_class: type[Base],
    *,
    memory_id: uuid.UUID,
    enrichment_version: int,
    **kwargs: Any,
) -> bool:
    """Insert a specialised-table row, skipping silently if it already exists.

    Uses ON CONFLICT DO NOTHING targeting the unique constraint on
    (memory_id, enrichment_version) that was added in migration 0013.
    Commits the session before returning so the caller sees the row.

    Args:
        session: An async SQLAlchemy session. The session is committed on success.
        model_class: The ORM model class (a subclass of grove.models.base.Base —
            Decision, PeopleInteraction, Appointment, or any future specialised
            table that carries the uq_{table}_memory_id_enrichment_version constraint).
        memory_id: FK referencing memories.id.
        enrichment_version: Classifier pipeline version (PIPELINE_VERSION in run.py).
        **kwargs: All remaining column values for the row.

    Returns:
        True if the row was inserted; False if the (memory_id, enrichment_version)
        pair already existed (i.e. the insert was skipped).
    """
    table = inspect(model_class).persist_selectable
    constraint_name = f"uq_{table.name}_memory_id_enrichment_version"

    values = {"memory_id": memory_id, "enrichment_version": enrichment_version, **kwargs}

    stmt = (
        pg_insert(model_class)
        .values(**values)
        .on_conflict_do_nothing(constraint=constraint_name)
        .returning(table.c.id)
    )

    result = await session.execute(stmt)
    await session.commit()

    inserted = result.fetchone() is not None
    logger.debug(
        "writers.insert_if_not_exists",
        table=table.name,
        memory_id=str(memory_id),
        enrichment_version=enrichment_version,
        inserted=inserted,
    )
    return inserted
