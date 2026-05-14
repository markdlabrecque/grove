"""Add intent_router columns + migrate tables_searched to JSONB

Revision ID: 0012
Revises: 0011
Create Date: 2026-05-14

Adds four intent-router telemetry columns to query_logs (analogous to the
synthesis_* columns added in 0011). Also migrates tables_searched from
ARRAY(Text) to JSONB so it can hold the structured
{"vector": true, "decisions": "matched"|"empty"|"skipped", ...} shape
required by the Phase 3 intent router.

The data migration converts existing array rows to a minimal JSONB document
{"vector": true, "decisions": "skipped", "people_interactions": "skipped",
 "tasks": "skipped", "appointments": "skipped"} so historical rows remain
valid after the migration.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

from alembic import op

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

def upgrade() -> None:
    # Add the new intent_router telemetry columns.
    op.add_column(
        "query_logs",
        sa.Column("intent_router_model", sa.Text(), nullable=True),
    )
    op.add_column(
        "query_logs",
        sa.Column("intent_router_input_tokens", sa.Integer(), nullable=True),
    )
    op.add_column(
        "query_logs",
        sa.Column("intent_router_output_tokens", sa.Integer(), nullable=True),
    )
    op.add_column(
        "query_logs",
        sa.Column("intent_router_cost", sa.Numeric(precision=12, scale=8), nullable=True),
    )

    # Migrate tables_searched from ARRAY(Text) to JSONB.
    # Step 1: add the new jsonb column alongside the old one.
    op.add_column(
        "query_logs",
        sa.Column("tables_searched_jsonb", JSONB(), nullable=True),
    )

    # Step 2: back-fill the new column from the old array column.
    # Existing rows get a canonical "all skipped" document.
    op.execute(
        sa.text(
            """
            UPDATE query_logs
            SET tables_searched_jsonb = '{
                "vector": true,
                "decisions": "skipped",
                "people_interactions": "skipped",
                "tasks": "skipped",
                "appointments": "skipped"
            }'::jsonb
            WHERE tables_searched_jsonb IS NULL
            """
        )
    )

    # Step 3: drop the old column and rename the new one.
    op.drop_column("query_logs", "tables_searched")
    op.alter_column("query_logs", "tables_searched_jsonb", new_column_name="tables_searched")

    # Step 4: set NOT NULL now that every row has a value.
    op.alter_column("query_logs", "tables_searched", nullable=False)


def downgrade() -> None:
    # Reverse the JSONB → ARRAY migration (lossy — structured data becomes a
    # simple array containing "memories" and "memory_chunks" for all rows).
    op.add_column(
        "query_logs",
        sa.Column(
            "tables_searched_array",
            sa.ARRAY(sa.Text()),
            nullable=True,
        ),
    )
    op.execute(
        sa.text("UPDATE query_logs SET tables_searched_array = ARRAY['memories', 'memory_chunks']")
    )
    op.drop_column("query_logs", "tables_searched")
    op.alter_column("query_logs", "tables_searched_array", new_column_name="tables_searched")
    op.alter_column("query_logs", "tables_searched", nullable=False)

    op.drop_column("query_logs", "intent_router_cost")
    op.drop_column("query_logs", "intent_router_output_tokens")
    op.drop_column("query_logs", "intent_router_input_tokens")
    op.drop_column("query_logs", "intent_router_model")
