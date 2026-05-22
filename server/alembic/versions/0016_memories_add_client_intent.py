"""Add client_intent to memories

Revision ID: 0016
Revises: 0015
Create Date: 2026-05-18

client_intent is set by the iOS client at capture time to signal explicit
user intent for a memory. V1 allowed value is "task"; nullable so existing
rows and captures without an explicit intent remain valid.

No CHECK constraint — left loose for forward compatibility so future intent
values ("note", "appointment", etc.) can be introduced without a new
migration.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0016"
down_revision: str | None = "0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "memories",
        sa.Column("client_intent", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    # No-op: migration 0019 permanently dropped the client_intent column.
    # Attempting to drop it here when downgrading 0016 → 0015 would raise
    # UndefinedColumnError because the column no longer exists in the schema.
    pass
