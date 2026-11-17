"""initial schema: patients, encounters, phi_access_log

Revision ID: 0001
Revises:
Create Date: 2026-10-01
"""

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "patients",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("external_ref", sa.String(64), nullable=False, unique=True),
        sa.Column("name_enc", sa.Text, nullable=False),
        sa.Column("dob_enc", sa.Text, nullable=False),
        sa.Column("email_enc", sa.Text),
        sa.Column("email_bidx", sa.String(64)),
        sa.Column("zip3", sa.String(3)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_patients_email_bidx", "patients", ["email_bidx"])

    op.create_table(
        "encounters",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("patient_id", sa.String(36), sa.ForeignKey("patients.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("encounter_type", sa.String(32), nullable=False),
        sa.Column("notes_enc", sa.Text),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_encounters_patient_id", "encounters", ["patient_id"])

    op.create_table(
        "phi_access_log",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("actor", sa.String(128), nullable=False),
        sa.Column("action", sa.String(16), nullable=False),
        sa.Column("resource_type", sa.String(32), nullable=False),
        sa.Column("resource_id", sa.String(36), nullable=False),
        sa.Column("request_id", sa.String(64), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_phi_access_log_occurred_at", "phi_access_log", ["occurred_at"])

    if op.get_bind().dialect.name == "postgresql":
        # Audit log is append-only at the database level, not just by convention.
        op.execute("REVOKE UPDATE, DELETE, TRUNCATE ON phi_access_log FROM PUBLIC")
        op.execute("""
            CREATE OR REPLACE FUNCTION phi_access_log_immutable() RETURNS trigger AS $$
            BEGIN RAISE EXCEPTION 'phi_access_log is append-only'; END; $$ LANGUAGE plpgsql
        """)
        op.execute("""
            CREATE TRIGGER phi_access_log_no_mutation BEFORE UPDATE OR DELETE ON phi_access_log
            FOR EACH ROW EXECUTE FUNCTION phi_access_log_immutable()
        """)


def downgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS phi_access_log_no_mutation ON phi_access_log")
        op.execute("DROP FUNCTION IF EXISTS phi_access_log_immutable()")
    op.drop_table("phi_access_log")
    op.drop_table("encounters")
    op.drop_table("patients")
