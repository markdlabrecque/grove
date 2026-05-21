from __future__ import annotations

import uuid
from typing import Annotated

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from grove.api.memories import TaskSchema
from grove.core.db import get_session
from grove.models.task import Task

logger = structlog.get_logger()

router = APIRouter()


@router.get(
    "/tasks",
    response_model=list[TaskSchema],
    status_code=status.HTTP_200_OK,
)
async def list_tasks(
    session: Annotated[AsyncSession, Depends(get_session)],
) -> list[TaskSchema]:
    """Return all tasks sorted by created_at descending.

    No pagination, no filter params. Returns every task row in the store,
    newest first. Filtering by memory or EventKit identifier was removed in
    spec 02 (Unit 1 / #451).
    """
    result = await session.execute(select(Task).order_by(Task.created_at.desc()))
    tasks = list(result.scalars().all())

    logger.info("tasks_listed", task_count=len(tasks))

    return [TaskSchema.model_validate(t) for t in tasks]


@router.delete(
    "/tasks/{task_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_task(
    task_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> None:
    """Delete a task row, returning 204 on success.

    Returns 404 whether the task does not exist OR does not belong to the
    authenticated user — same shape either way to avoid existence leaks. The
    single query gates both conditions.
    """
    result = await session.execute(select(Task).where(Task.id == task_id))
    task = result.scalar_one_or_none()

    if task is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="task not found")

    await session.delete(task)
    await session.commit()

    logger.info("task_deleted", task_id=str(task_id))
