"""Query refinement detection (ticket #176, implementation plan §3.8).

When a new query arrives, fetch the most recent prior query_log row whose
created_at is within the configured window. If one exists and the cosine
similarity between its embedding and the new query's embedding meets the
threshold, the new query is a refinement of the prior one.

This runs before synthesis/intent-router so it adds no latency to the
user-facing answer — it only stamps the new query_log row.
"""

from __future__ import annotations

import uuid

import structlog
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from oracle.core.config import RefinementConfig, settings

logger = structlog.get_logger()


async def detect_refinement(
    session_factory: async_sessionmaker[AsyncSession],
    new_embedding: list[float],
    config: RefinementConfig | None = None,
) -> tuple[bool, uuid.UUID] | None:
    """Return (True, prior_id) when the new query is a refinement, else None.

    Fetches the single most recent query_log row within the configured window,
    then uses pgvector's `<=>` cosine-distance operator to compute similarity.
    The window filter runs in SQL so the round-trip is a single query.

    Args:
        session_factory: Session factory to open a short-lived connection.
        new_embedding: The embedding vector for the incoming query.
        config: Optional RefinementConfig override (used in tests). When None,
                the value from oracle.core.config.settings.refinement is used.
    """
    cfg: RefinementConfig = config if config is not None else settings.refinement

    try:
        async with session_factory() as session:
            # Fetch the most recent prior row within the time window.
            # created_at column has timezone=True so now() gives a tz-aware ts.
            stmt = session.execute(
                text(
                    """
                        SELECT id, query_embedding <=> :vec AS distance
                        FROM query_logs
                        WHERE created_at >= now() - make_interval(mins => :window)
                          AND query_embedding IS NOT NULL
                        ORDER BY created_at DESC
                        LIMIT 1
                        """
                ),
                {
                    "vec": str(new_embedding),
                    "window": cfg.window_minutes,
                },
            )
            result = await stmt
            row = result.fetchone()

            if row is None:
                return None

            similarity = 1.0 - float(row.distance)
            if similarity >= cfg.similarity_threshold:
                logger.info(
                    "refinement_detected",
                    parent_query_id=str(row.id),
                    similarity=round(similarity, 4),
                )
                return True, row.id

            return None

    except SQLAlchemyError as exc:
        # Detection failure must not surface to the caller — it's telemetry only.
        logger.warning("refinement_detection_failed", error=repr(exc))
        return None
