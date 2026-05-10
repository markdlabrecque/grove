"""Create people_interactions table

Revision ID: 0007
Revises: 0006
Create Date: 2026-05-09

Prototype V1 specialized table (PRD §8.3, §13.1). This table will evolve
or be deprecated based on observed enrichment signal (PRD §11).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ARRAY

from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "people_interactions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("memory_id", sa.UUID(), nullable=False),
        sa.Column("person_name", sa.Text(), nullable=False),
        sa.Column("interaction_medium", sa.Text(), nullable=True),
        sa.Column("topics", ARRAY(sa.Text()), nullable=True),
        sa.Column("next_steps", ARRAY(sa.Text()), nullable=True),
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
    op.create_index("ix_people_interactions_memory_id", "people_interactions", ["memory_id"])
    # Supports "what did I talk to X about" queries (impl plan §Schema additions).
    op.create_index("ix_people_interactions_person_name", "people_interactions", ["person_name"])


def downgrade() -> None:
    op.drop_index("ix_people_interactions_person_name", table_name="people_interactions")
    op.drop_index("ix_people_interactions_memory_id", table_name="people_interactions")
    op.drop_table("people_interactions")
