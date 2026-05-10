"""Create query_logs table

Revision ID: 0004
Revises: 0003
Create Date: 2026-05-09

"""

from collections.abc import Sequence

import sqlalchemy as sa
from pgvector.sqlalchemy import Vector
from sqlalchemy.dialects.postgresql import ARRAY, UUID

from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "query_logs",
        sa.Column("id", UUID(as_uuid=True), nullable=False),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("query_text", sa.Text(), nullable=False),
        sa.Column("query_embedding", Vector(1536), nullable=True),
        sa.Column("tables_searched", ARRAY(sa.Text()), nullable=False),
        sa.Column("result_count", sa.Integer(), nullable=False),
        # returned_memory_ids is a plain UUID array with no FK constraint.
        # Query logs are retained even when referenced memories are deleted
        # (PRD §6.6). Enforcing referential integrity here would cause log
        # entries to be lost on memory deletion, which defeats the purpose of
        # the observability layer.
        sa.Column("returned_memory_ids", ARRAY(UUID(as_uuid=True)), nullable=True),
        sa.Column("synthesis_model", sa.Text(), nullable=True),
        sa.Column("synthesis_input_tokens", sa.Integer(), nullable=True),
        sa.Column("synthesis_output_tokens", sa.Integer(), nullable=True),
        sa.Column("user_feedback", sa.Text(), nullable=True),
        sa.Column("feedback_at", sa.TIMESTAMP(timezone=True), nullable=True),
        sa.Column(
            "is_refinement",
            sa.Boolean(),
            server_default=sa.text("false"),
            nullable=True,
        ),
        sa.Column("parent_query_id", UUID(as_uuid=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["parent_query_id"],
            ["query_logs.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    # Index for the weekly-review time-window query path (PRD §11).
    op.create_index("ix_query_logs_created_at", "query_logs", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_query_logs_created_at", table_name="query_logs")
    op.drop_table("query_logs")
