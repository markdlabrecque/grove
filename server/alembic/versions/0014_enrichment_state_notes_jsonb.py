"""Change enrichment_state.notes from Text to JSONB

Revision ID: 0014
Revises: 0013
Create Date: 2026-05-14

The notes column was created as Text in 0005. Ticket #182 writes a structured
RunReport into it; JSONB is the appropriate Postgres type for indexed,
operator-accessible JSON.  Existing NULL values are unaffected.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

from alembic import op

revision: str = "0014"
down_revision: str | None = "0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "enrichment_state",
        "notes",
        existing_type=sa.Text(),
        type_=JSONB(),
        existing_nullable=True,
        postgresql_using="notes::jsonb",
    )


def downgrade() -> None:
    op.alter_column(
        "enrichment_state",
        "notes",
        existing_type=JSONB(),
        type_=sa.Text(),
        existing_nullable=True,
        postgresql_using="notes::text",
    )
