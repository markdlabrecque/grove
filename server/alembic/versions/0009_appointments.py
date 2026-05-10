"""Create appointments table

Revision ID: 0009
Revises: 0008
Create Date: 2026-05-09

Prototype V1 specialized table (impl plan §Schema additions, PRD §13.1).
This table will evolve or be deprecated based on observed enrichment signal
(PRD §11). starts_at and ends_at are best-effort LLM extractions.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ARRAY

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "appointments",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("memory_id", sa.UUID(), nullable=False),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("starts_at", sa.TIMESTAMP(timezone=True), nullable=True),
        sa.Column("ends_at", sa.TIMESTAMP(timezone=True), nullable=True),
        sa.Column("location", sa.Text(), nullable=True),
        sa.Column("participants", ARRAY(sa.Text()), nullable=True),
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
    op.create_index("ix_appointments_memory_id", "appointments", ["memory_id"])
    op.create_index("ix_appointments_starts_at", "appointments", ["starts_at"])


def downgrade() -> None:
    op.drop_index("ix_appointments_starts_at", table_name="appointments")
    op.drop_index("ix_appointments_memory_id", table_name="appointments")
    op.drop_table("appointments")
