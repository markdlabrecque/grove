"""Add synthesis_cost to query_logs

Revision ID: 0011
Revises: 0010
Create Date: 2026-05-14

synthesis_cost captures the USD cost returned by OpenRouter's
x-openrouter-cost header for each synthesis call. Nullable — NULL when
synthesis was not attempted or failed before cost was known.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "query_logs",
        sa.Column("synthesis_cost", sa.Numeric(precision=12, scale=8), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("query_logs", "synthesis_cost")
