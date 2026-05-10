"""Create decisions table

Revision ID: 0006
Revises: 0005
Create Date: 2026-05-09

Prototype V1 specialized table (PRD §8.3, §13.1). This table will evolve
or be deprecated based on observed enrichment signal (PRD §11).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ARRAY

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "decisions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("memory_id", sa.UUID(), nullable=False),
        sa.Column("decision_maker", sa.Text(), nullable=True),
        sa.Column("context", sa.Text(), nullable=True),
        sa.Column("options", ARRAY(sa.Text()), nullable=True),
        sa.Column("chosen_option", sa.Text(), nullable=True),
        sa.Column("rationale", sa.Text(), nullable=True),
        sa.Column("outcome", sa.Text(), nullable=True),
        sa.Column("outcome_date", sa.Date(), nullable=True),
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
    op.create_index("ix_decisions_memory_id", "decisions", ["memory_id"])


def downgrade() -> None:
    op.drop_index("ix_decisions_memory_id", table_name="decisions")
    op.drop_table("decisions")
