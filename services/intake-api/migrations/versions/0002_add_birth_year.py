"""expand: add patients.birth_year (Safe Harbor-generalized DOB for analytics)

Expand/contract example. This release only ADDS a nullable column and
backfills it in batches; the app writes it for new rows. A NOT NULL
constraint, if ever wanted, ships in a later release after the backfill is
verified, using NOT VALID + VALIDATE CONSTRAINT to avoid a long lock.

Backfill runs as a one-off ECS task under the intake-api task role, the only
principal allowed to kms:Decrypt dob_enc. Plain SQL can't do it, by design.

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-20
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("patients", sa.Column("birth_year", sa.Integer, nullable=True))


def downgrade() -> None:
    op.drop_column("patients", "birth_year")
