from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(UTC)


class Base(DeclarativeBase):
    pass


class Patient(Base):
    """Direct identifiers are stored only as ciphertext (*_enc columns).

    zip3 and birth_year are stored in clear because they are the generalized
    forms permitted under HIPAA Safe Harbor and are needed for analytics joins.
    """

    __tablename__ = "patients"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    external_ref: Mapped[str] = mapped_column(String(64), unique=True)
    name_enc: Mapped[str] = mapped_column(Text)
    dob_enc: Mapped[str] = mapped_column(Text)
    email_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    email_bidx: Mapped[str | None] = mapped_column(String(64), nullable=True)
    zip3: Mapped[str | None] = mapped_column(String(3), nullable=True)
    birth_year: Mapped[int | None] = mapped_column(nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)

    __table_args__ = (Index("ix_patients_email_bidx", "email_bidx"),)


class Encounter(Base):
    __tablename__ = "encounters"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    patient_id: Mapped[str] = mapped_column(ForeignKey("patients.id", ondelete="RESTRICT"), index=True)
    encounter_type: Mapped[str] = mapped_column(String(32))
    notes_enc: Mapped[str | None] = mapped_column(Text, nullable=True)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class PhiAccessLog(Base):
    """Append-only audit trail of PHI reads/writes (HIPAA 164.312(b))."""

    __tablename__ = "phi_access_log"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    actor: Mapped[str] = mapped_column(String(128))
    action: Mapped[str] = mapped_column(String(16))
    resource_type: Mapped[str] = mapped_column(String(32))
    resource_id: Mapped[str] = mapped_column(String(36))
    request_id: Mapped[str] = mapped_column(String(64))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, index=True)
