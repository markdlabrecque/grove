"""Add captured_at to memories

Revision ID: 0010
Revises: 0009
Create Date: 2026-05-09

captured_at is the client-supplied timestamp (the moment the user tapped Save
on-device). Distinct from created_at (server ingestion time). Nullable so
existing rows without a client timestamp remain valid.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "memories",
        sa.Column("captured_at", sa.TIMESTAMP(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("memories", "captured_at")
