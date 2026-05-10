"""Create enrichment_state table

Revision ID: 0005
Revises: 0004
Create Date: 2026-05-09

"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "enrichment_state",
        sa.Column("id", UUID(as_uuid=True), nullable=False),
        sa.Column("run_started_at", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("run_completed_at", sa.TIMESTAMP(timezone=True), nullable=True),
        sa.Column("pipeline_version", sa.Integer(), nullable=False),
        sa.Column(
            "memories_processed",
            sa.Integer(),
            server_default=sa.text("0"),
            nullable=False,
        ),
        sa.Column(
            "classifications_created",
            sa.Integer(),
            server_default=sa.text("0"),
            nullable=False,
        ),
        sa.Column(
            "errors",
            sa.Integer(),
            server_default=sa.text("0"),
            nullable=False,
        ),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade() -> None:
    op.drop_table("enrichment_state")
