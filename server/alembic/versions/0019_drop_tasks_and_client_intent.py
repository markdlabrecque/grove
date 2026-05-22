"""Drop tasks table and Memory.client_intent column

Revision ID: 0019
Revises: 0018
Create Date: 2026-05-22

Forward-only cleanup. The tasks table and all code that wrote to it have been
removed across #451–#488. The client_intent column on memories was added in
0016 solely to track "task" intent captures; that path was removed in #487.
Both are now fully dead.

Downgrade is a no-op: restoring the table and column would be meaningless
without the application code, and alembic downgrade base must walk the chain
cleanly in CI.  The downgrade stubs in 0008, 0013, 0015, 0018 (and this file)
are silenced for the same reason — the tasks table no longer exists when those
downgrades run.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0019"
down_revision: str | None = "0018"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Drop indexes first (Postgres requires this before dropping the table).
    # uq_tasks_memory_id_capture_time was created via raw op.execute() in 0018,
    # so use IF EXISTS to guard against environments where 0018 was not applied
    # (or the index was otherwise absent).
    op.execute("DROP INDEX IF EXISTS uq_tasks_memory_id_capture_time")
    op.drop_index("ix_tasks_due_date", table_name="tasks")
    op.drop_index("ix_tasks_memory_id", table_name="tasks")
    op.drop_table("tasks")

    op.drop_column("memories", "client_intent")


def downgrade() -> None:
    # Forward-only migration — restoring the tasks table and client_intent
    # column without the application code that used them is meaningless.
    pass
