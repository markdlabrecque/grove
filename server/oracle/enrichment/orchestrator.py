"""Per-memory classify-and-write orchestrator (ticket #180).

Public API:
    classify_and_write(memory, session, *, report=None)
        Classify *memory* using #179's classifier, then write accepted
        extractions (confidence >= CONFIDENCE_THRESHOLD) to the four
        specialised tables in the same transaction that is owned by
        the caller.  Marks memory.enriched = True on success; sets
        memory.enrichment_error and leaves enriched = False on failure.
        When *report* is provided (injected by the worker), token counts,
        costs, accepted extractions, and errors are accumulated there.

Transaction contract:
    classify_and_write does NOT commit or roll back the session itself
    on the happy path — it calls session.commit() exactly once at the
    end so that all four writers + the memory update are atomic.  On
    failure (ClassificationError, SkippedReason, or any writer
    exception) it rolls back and sets enrichment_error on the memory
    row using a separate flush.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

import structlog
from sqlalchemy import inspect
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from oracle.admin.spend import SpendCapExceededError, check_spend_cap
from oracle.enrichment.classifier import ClassificationError, SkippedReason, classify_memory
from oracle.enrichment.schemas import load_classification_prompts
from oracle.models import Appointment, Decision, Memory, PeopleInteraction, Task

if TYPE_CHECKING:
    from oracle.enrichment.report import RunReport

logger = structlog.get_logger(__name__)

# Extractions below this threshold are silently dropped.
CONFIDENCE_THRESHOLD = 0.7


async def insert_if_not_exists(
    session: AsyncSession,
    model_class: type,
    *,
    memory_id: uuid.UUID,
    enrichment_version: int,
    **kwargs: Any,
) -> bool:
    """Upsert a specialised-table row without committing the session.

    Unlike oracle.enrichment.writers.insert_if_not_exists, this variant
    does NOT commit.  The caller (classify_and_write) owns the transaction
    boundary and commits exactly once after all four writers succeed.

    Uses ON CONFLICT DO NOTHING targeting the unique constraint on
    (memory_id, enrichment_version), making concurrent double-claims safe.

    Returns True if the row was inserted, False if it already existed.
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
    inserted = result.fetchone() is not None

    logger.debug(
        "orchestrator.insert_if_not_exists",
        table=table.name,
        memory_id=str(memory_id),
        enrichment_version=enrichment_version,
        inserted=inserted,
    )
    return inserted


async def classify_and_write(
    memory: Memory,
    session: AsyncSession,
    *,
    report: RunReport | None = None,
    spend_session_factory: async_sessionmaker[AsyncSession] | None = None,
) -> None:
    """Classify *memory* and write accepted extractions to specialised tables.

    Called once per memory by the enrichment worker.  All database writes
    (specialised-table inserts + memory.enriched = True) happen inside a
    single transaction that this function commits on success.

    On SpendCapExceededError:
        - Sets memory.enrichment_error = "spend_cap_exceeded".
        - Leaves memory.enriched = False.
        - Does not call the LLM or write any specialised rows.

    On SkippedReason or ClassificationError:
        - Sets memory.enrichment_error.
        - Leaves memory.enriched = False.
        - Does not write any specialised rows.

    On any writer exception:
        - Rolls back the session.
        - Sets memory.enrichment_error.
        - Leaves memory.enriched = False.

    Args:
        memory: The Memory ORM object loaded within *session*.
        session: An async SQLAlchemy session.  Committed on success;
            rolled back on failure.  The caller must NOT commit after
            returning — classify_and_write owns the commit.
        report: Optional RunReport accumulator injected by the worker.  When
            provided, token counts, costs, accepted extractions, and errors
            are recorded here for the per-run summary.
        spend_session_factory: Session factory used exclusively for the
            spend-cap check.  The worker passes its own factory (same engine,
            NullPool) so the check runs on a separate connection without
            touching the per-memory transaction.  When None a fresh NullPool
            engine is created from settings.database_url.
    """
    from oracle.core.config import settings
    from oracle.enrichment.run import PIPELINE_VERSION

    log = logger.bind(memory_id=str(memory.id))

    # --- Guard: skip if monthly spend cap is exceeded ---
    if spend_session_factory is None:
        # Derive a factory from the caller's session engine.  This keeps the
        # spend check on the same engine (and event loop) as the per-memory
        # session, avoiding asyncpg "different loop" errors in test environments
        # while still opening a separate connection for the check.
        spend_session_factory = async_sessionmaker(session.bind, expire_on_commit=False)
    try:
        await check_spend_cap(spend_session_factory)
    except SpendCapExceededError:
        log.warning("orchestrator.spend_cap_exceeded", memory_id=str(memory.id))
        memory.enrichment_error = "spend_cap_exceeded"
        await session.commit()
        return

    # --- Load prompt bundle ---
    prompt_bundle = load_classification_prompts(PIPELINE_VERSION)

    # --- Call classifier ---
    api_key = settings.openrouter_api_key.get_secret_value() if settings.openrouter_api_key else ""
    try:
        result = await classify_memory(
            memory,
            prompt_bundle,
            api_key=api_key,
        )
    except ClassificationError as exc:
        log.warning("orchestrator.classification_error", error=str(exc))
        if report is not None:
            report.record_error(str(exc))
        memory.enrichment_error = str(exc)
        await session.commit()
        return

    if isinstance(result, SkippedReason):
        log.info("orchestrator.skipped", reason=str(result))
        memory.enrichment_error = str(result)
        await session.commit()
        return

    # result is a ClassificationResult — record LLM usage regardless of what
    # gets accepted below.
    classification = result.classification
    if report is not None:
        report.record_llm_usage(
            input_tokens=result.prompt_tokens,
            output_tokens=result.completion_tokens,
            cost_usd=result.cost_usd,
        )

    # --- Write accepted extractions, all in this transaction ---
    try:
        accepted = 0
        dropped = 0

        for decision in classification.decisions:
            if decision.confidence >= CONFIDENCE_THRESHOLD:
                await insert_if_not_exists(
                    session,
                    Decision,
                    memory_id=memory.id,
                    enrichment_version=PIPELINE_VERSION,
                    decision_maker=decision.decision_maker,
                    context=decision.context,
                    options=decision.options,
                    chosen_option=decision.chosen_option,
                    rationale=decision.rationale,
                    outcome=decision.outcome,
                    outcome_date=decision.outcome_date,
                    confidence=decision.confidence,
                )
                if report is not None:
                    report.record_accepted("decisions", confidence=decision.confidence)
                accepted += 1
            else:
                if report is not None:
                    report.record_dropped()
                dropped += 1

        for interaction in classification.people_interactions:
            if interaction.confidence >= CONFIDENCE_THRESHOLD:
                await insert_if_not_exists(
                    session,
                    PeopleInteraction,
                    memory_id=memory.id,
                    enrichment_version=PIPELINE_VERSION,
                    person_name=interaction.person_name,
                    interaction_medium=interaction.interaction_medium,
                    topics=interaction.topics,
                    next_steps=interaction.next_steps,
                    confidence=interaction.confidence,
                )
                if report is not None:
                    report.record_accepted("people_interactions", confidence=interaction.confidence)
                accepted += 1
            else:
                if report is not None:
                    report.record_dropped()
                dropped += 1

        for task in classification.tasks:
            if task.confidence >= CONFIDENCE_THRESHOLD:
                await insert_if_not_exists(
                    session,
                    Task,
                    memory_id=memory.id,
                    enrichment_version=PIPELINE_VERSION,
                    description=task.description,
                    due_date=task.due_date,
                    status=task.status,
                    related_people=task.related_people,
                    confidence=task.confidence,
                )
                if report is not None:
                    report.record_accepted("tasks", confidence=task.confidence)
                accepted += 1
            else:
                if report is not None:
                    report.record_dropped()
                dropped += 1

        for appointment in classification.appointments:
            if appointment.confidence >= CONFIDENCE_THRESHOLD:
                await insert_if_not_exists(
                    session,
                    Appointment,
                    memory_id=memory.id,
                    enrichment_version=PIPELINE_VERSION,
                    title=appointment.title,
                    starts_at=appointment.starts_at,
                    ends_at=appointment.ends_at,
                    location=appointment.location,
                    participants=appointment.participants,
                    confidence=appointment.confidence,
                )
                if report is not None:
                    report.record_accepted("appointments", confidence=appointment.confidence)
                accepted += 1
            else:
                if report is not None:
                    report.record_dropped()
                dropped += 1

        # --- Mark memory enriched ---
        memory.enriched = True
        memory.enriched_at = datetime.now(tz=UTC)
        memory.enriched_version = PIPELINE_VERSION
        memory.enrichment_error = None

        await session.commit()

        log.info(
            "orchestrator.classify_and_write.ok",
            accepted=accepted,
            dropped=dropped,
            pipeline_version=PIPELINE_VERSION,
        )

    except Exception as exc:
        await session.rollback()
        log.warning("orchestrator.writer_error", error=str(exc))
        if report is not None:
            report.record_error(str(exc))
        # Surface the error on the memory row for retry on next run.
        memory.enrichment_error = str(exc)
        await session.commit()
