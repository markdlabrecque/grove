"""Create memory_chunks table

Revision ID: 0003
Revises: 0002
Create Date: 2026-05-09

"""

from collections.abc import Sequence

import sqlalchemy as sa
from pgvector.sqlalchemy import Vector

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "memory_chunks",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("memory_id", sa.UUID(), nullable=False),
        sa.Column("chunk_index", sa.Integer(), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("embedding", Vector(1536), nullable=False),
        sa.Column("embedding_model", sa.Text(), nullable=False),
        sa.ForeignKeyConstraint(
            ["memory_id"],
            ["memories.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("memory_id", "chunk_index", name="uq_memory_chunk_index"),
    )
    op.create_index("ix_memory_chunks_memory_id", "memory_chunks", ["memory_id"])
    # HNSW index for cosine similarity search on chunk-level embeddings.
    op.execute(
        "CREATE INDEX ix_memory_chunks_embedding_hnsw ON memory_chunks "
        "USING hnsw (embedding vector_cosine_ops)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_memory_chunks_embedding_hnsw")
    op.drop_index("ix_memory_chunks_memory_id", table_name="memory_chunks")
    op.drop_table("memory_chunks")
