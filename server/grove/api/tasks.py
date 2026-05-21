from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from grove.api.memories import TaskSchema
from grove.core.db import get_session
from grove.models.task import Task

logger = structlog.get_logger()

router = APIRouter()


class TaskEventKitLinkRequest(BaseModel):
    eventkit_identifier: str = Field(..., min_length=1)


@router.get(
    "/tasks",
    response_model=list[TaskSchema],
    status_code=status.HTTP_200_OK,
)
async def list_tasks(
    session: Annotated[AsyncSession, Depends(get_session)],
    memory_ids: Annotated[str, Query()] = "",
    eventkit_identifiers: Annotated[str, Query()] = "",
) -> list[TaskSchema]:
    """Return tasks filtered by memory_id or eventkit_identifier.

    Exactly one of memory_ids or eventkit_identifiers may be supplied per
    request. Passing both returns 422. Empty/absent values return 200 [].

    memory_ids: comma-separated UUIDs — each token is validated.
    eventkit_identifiers: comma-separated opaque strings
        (EKReminder.calendarItemIdentifier) — no UUID validation performed.
    """
    has_memory_ids = bool(memory_ids.strip())
    has_ek_ids = bool(eventkit_identifiers.strip())

    if has_memory_ids and has_ek_ids:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="cannot combine memory_ids and eventkit_identifiers",
        )

    if has_memory_ids:
        parsed_uuids: list[uuid.UUID] = []
        for raw in memory_ids.split(","):
            raw = raw.strip()
            if not raw:
                continue
            try:
                parsed_uuids.append(uuid.UUID(raw))
            except ValueError as exc:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"invalid UUID in memory_ids: {raw!r}",
                ) from exc

        if not parsed_uuids:
            return []

        result = await session.execute(select(Task).where(Task.memory_id.in_(parsed_uuids)))
        tasks = list(result.scalars().all())

        logger.info(
            "tasks_listed_by_memory_ids",
            memory_id_count=len(parsed_uuids),
            task_count=len(tasks),
        )

        return [TaskSchema.model_validate(t) for t in tasks]

    if has_ek_ids:
        parsed_ek: list[str] = [
            tok for tok in (t.strip() for t in eventkit_identifiers.split(",")) if tok
        ]

        if not parsed_ek:
            return []

        result = await session.execute(select(Task).where(Task.eventkit_identifier.in_(parsed_ek)))
        tasks = list(result.scalars().all())

        logger.info(
            "tasks_listed_by_eventkit_identifiers",
            identifier_count=len(parsed_ek),
            task_count=len(tasks),
        )

        return [TaskSchema.model_validate(t) for t in tasks]

    return []


@router.patch(
    "/tasks/{task_id}",
    response_model=TaskSchema,
    status_code=status.HTTP_200_OK,
)
async def link_task_eventkit(
    task_id: uuid.UUID,
    body: TaskEventKitLinkRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> TaskSchema:
    """Attach an EventKit calendarItemIdentifier to a task row.

    Idempotency: a task may only be linked once. A second request returns
    409 with the existing identifier so the iOS client can self-heal without
    needing to query the task first.
    """
    result = await session.execute(select(Task).where(Task.id == task_id))
    task = result.scalar_one_or_none()

    if task is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="task not found")

    if task.eventkit_identifier is not None:
        logger.info(
            "task_eventkit_already_linked",
            task_id=str(task_id),
            existing_identifier=task.eventkit_identifier,
        )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "detail": "task already linked to an EventKit reminder",
                "existing_identifier": task.eventkit_identifier,
            },
        )

    task.eventkit_identifier = body.eventkit_identifier
    task.eventkit_linked_at = datetime.now(tz=UTC)
    await session.commit()

    logger.info(
        "task_eventkit_linked",
        task_id=str(task_id),
        eventkit_identifier=task.eventkit_identifier,
    )

    return TaskSchema.model_validate(task)
