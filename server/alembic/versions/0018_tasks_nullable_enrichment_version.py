"""Make tasks.enrichment_version nullable to support capture-time task insertion

Revision ID: 0018
Revises: 0017
Create Date: 2026-05-22

When a task row is created at POST /v1/captures time (before enrichment runs),
there is no PIPELINE_VERSION to stamp yet.  NULL is the correct sentinel for
"inserted at capture time, not yet enriched".  The enrichment worker updates the
column (and populates due_date / related_people) when it processes the memory.

Downgrade restores NOT NULL.  A fresh DB will have no capture-time rows, so the
constraint restore is safe against Alembic's 'alembic downgrade base' pass in CI.

The composite unique constraint uq_tasks_memory_id_enrichment_version (0013) does
NOT protect against duplicate capture-time rows because Postgres treats every NULL
as distinct in a unique index.  A partial unique index on (memory_id) WHERE
enrichment_version IS NULL closes that gap.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0018"
down_revision: str | None = "0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("tasks", "enrichment_version", existing_type=sa.Integer(), nullable=True)
    # Partial unique index: at most one capture-time (enrichment_version IS NULL)
    # row per memory.  The standard composite constraint (0013) cannot enforce this
    # because Postgres treats NULLs as distinct in unique indexes.
    op.execute(
        """
        CREATE UNIQUE INDEX uq_tasks_memory_id_capture_time
            ON tasks (memory_id)
            WHERE enrichment_version IS NULL
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS uq_tasks_memory_id_capture_time")
    op.alter_column("tasks", "enrichment_version", existing_type=sa.Integer(), nullable=False)
