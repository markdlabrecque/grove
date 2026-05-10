"""Create tasks table

Revision ID: 0008
Revises: 0007
Create Date: 2026-05-09

Prototype V1 specialized table (impl plan §Schema additions, PRD §13.1).
This table will evolve or be deprecated based on observed enrichment signal
(PRD §11). V1 status is always 'open'; lifecycle management is deferred.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ARRAY

from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "tasks",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("memory_id", sa.UUID(), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("due_date", sa.Date(), nullable=True),
        sa.Column("status", sa.Text(), nullable=True),
        sa.Column("related_people", ARRAY(sa.Text()), nullable=True),
        sa.Column("confidence", sa.Float(), nullable=False),
        sa.Column("enrichment_version", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["memory_id"],
            ["memories.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_tasks_memory_id", "tasks", ["memory_id"])
    op.create_index("ix_tasks_due_date", "tasks", ["due_date"])


def downgrade() -> None:
    op.drop_index("ix_tasks_due_date", table_name="tasks")
    op.drop_index("ix_tasks_memory_id", table_name="tasks")
    op.drop_table("tasks")
