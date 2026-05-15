"""Add unique (memory_id, enrichment_version) constraints to specialised tables

Revision ID: 0013
Revises: 0012
Create Date: 2026-05-14

Guards against duplicate specialised-table inserts when two enrichment workers
claim the same memory IDs after the batch_session.commit() fix (#199). The
unique constraint on (memory_id, enrichment_version) enables ON CONFLICT DO
NOTHING upsert semantics: a duplicate classify_and_write call is a safe no-op.

The constraint is intentionally on (memory_id, enrichment_version), NOT just
memory_id, so re-enrichment (bumping enrichment_version) is still allowed and
produces a new row.

See #201 for full context.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_TABLES = ("decisions", "people_interactions", "tasks", "appointments")


def upgrade() -> None:
    for table in _TABLES:
        op.create_unique_constraint(
            f"uq_{table}_memory_id_enrichment_version",
            table,
            ["memory_id", "enrichment_version"],
        )


def downgrade() -> None:
    for table in _TABLES:
        op.drop_constraint(
            f"uq_{table}_memory_id_enrichment_version",
            table,
            type_="unique",
        )
