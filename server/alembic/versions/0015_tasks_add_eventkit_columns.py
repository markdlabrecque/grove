"""Add EventKit linking columns to tasks table

Revision ID: 0015
Revises: 0014
Create Date: 2026-05-18

Bridges Grove-extracted tasks to Apple Reminders via EventKit (#391).
The iOS client calls PATCH /v1/tasks/{id} after creating an EKReminder,
storing the calendarItemIdentifier here. No server-side sync — EventKit
is the source of truth for completion state at read time.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0015"
down_revision: str | None = "0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("tasks", sa.Column("eventkit_identifier", sa.Text(), nullable=True))
    op.add_column(
        "tasks",
        sa.Column("eventkit_linked_at", sa.TIMESTAMP(timezone=True), nullable=True),
    )


def downgrade() -> None:
    # No-op: migration 0017 permanently dropped these columns. Attempting to
    # drop them here when downgrading 0015 → 0014 would raise
    # UndefinedColumnError because they no longer exist in the schema.
    pass
