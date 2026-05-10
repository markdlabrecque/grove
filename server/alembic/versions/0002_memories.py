"""Create memories table

Revision ID: 0002
Revises: 0001
Create Date: 2026-05-09

"""

from collections.abc import Sequence

import sqlalchemy as sa
from pgvector.sqlalchemy import Vector

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "memories",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.TIMESTAMP(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("source_modality", sa.Text(), nullable=True),
        sa.Column("source_device", sa.Text(), nullable=True),
        sa.Column("language", sa.Text(), nullable=True),
        sa.Column("token_count", sa.Integer(), nullable=True),
        sa.Column("embedding_model", sa.Text(), nullable=True),
        sa.Column("embedding", Vector(1536), nullable=True),
        sa.Column("client_id", sa.UUID(), nullable=False),
        sa.Column(
            "enriched",
            sa.Boolean(),
            server_default=sa.text("false"),
            nullable=False,
        ),
        sa.Column("enriched_at", sa.TIMESTAMP(timezone=True), nullable=True),
        sa.Column("enriched_version", sa.Integer(), nullable=True),
        sa.Column("enrichment_error", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("client_id", name="uq_memories_client_id"),
    )
    op.create_index("ix_memories_enriched", "memories", ["enriched"])
    op.create_index("ix_memories_created_at", "memories", ["created_at"])
    # HNSW index for cosine similarity search on memory-level embeddings.
    op.execute(
        "CREATE INDEX ix_memories_embedding_hnsw ON memories "
        "USING hnsw (embedding vector_cosine_ops)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_memories_embedding_hnsw")
    op.drop_index("ix_memories_created_at", table_name="memories")
    op.drop_index("ix_memories_enriched", table_name="memories")
    op.drop_table("memories")
