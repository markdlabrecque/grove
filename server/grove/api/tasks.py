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
async def list_tasks_by_memory_ids(
    session: Annotated[AsyncSession, Depends(get_session)],
    memory_ids: Annotated[str, Query()] = "",
) -> list[TaskSchema]:
    """Return tasks whose memory_id is in the supplied comma-separated list.

    Empty list → 200 with []. Unknown memory IDs are silently ignored.
    Used by the iOS foreground sweep to batch-look up tasks for all entries
    in PendingReminderStore without N round-trips through GET /v1/memories/{id}.
    """
    if not memory_ids.strip():
        return []

    parsed: list[uuid.UUID] = []
    for raw in memory_ids.split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            parsed.append(uuid.UUID(raw))
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"invalid UUID in memory_ids: {raw!r}",
            ) from exc

    if not parsed:
        return []

    result = await session.execute(select(Task).where(Task.memory_id.in_(parsed)))
    tasks = list(result.scalars().all())

    logger.info("tasks_listed_by_memory_ids", memory_id_count=len(parsed), task_count=len(tasks))

    return [TaskSchema.model_validate(t) for t in tasks]


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
