from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from grove.core.db import get_session
from grove.models.task import Task

logger = structlog.get_logger()

router = APIRouter()


class TaskEventKitLinkRequest(BaseModel):
    eventkit_identifier: str = Field(..., min_length=1)


class TaskEventKitLinkResponse(BaseModel):
    id: uuid.UUID
    memory_id: uuid.UUID
    description: str
    eventkit_identifier: str | None
    eventkit_linked_at: datetime | None

    model_config = {"from_attributes": True}


@router.patch(
    "/tasks/{task_id}",
    response_model=TaskEventKitLinkResponse,
    status_code=status.HTTP_200_OK,
)
async def link_task_eventkit(
    task_id: uuid.UUID,
    body: TaskEventKitLinkRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> TaskEventKitLinkResponse:
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
        eventkit_identifier=body.eventkit_identifier,
    )

    return TaskEventKitLinkResponse.model_validate(task)
