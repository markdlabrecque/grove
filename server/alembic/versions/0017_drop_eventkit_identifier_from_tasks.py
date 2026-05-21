"""Drop EventKit linking columns from tasks table

Revision ID: 0017
Revises: 0016
Create Date: 2026-05-21

Forward-only cleanup migration. The eventkit_identifier and eventkit_linked_at
columns were added in 0015 (#391) to bridge Grove tasks to Apple Reminders via
EventKit. The iOS PATCH /v1/tasks/{id} handler that wrote these columns was
removed in the Tasks tab rebuild (Part 2 of #404 spec). The columns are now
entirely dead — no server path reads or writes them.

Downgrade intentionally raises NotImplementedError: restoring the columns
would be meaningless without the PATCH handler, and any previously stored
values have already been abandoned by the iOS client. Callers that need to
recover should re-add the columns via a new forward migration.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0017"
down_revision: str | None = "0016"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_column("tasks", "eventkit_linked_at")
    op.drop_column("tasks", "eventkit_identifier")


def downgrade() -> None:
    raise NotImplementedError(
        "forward-only cleanup of dead EventKit-coupling columns — "
        "see migration docstring for rationale"
    )
