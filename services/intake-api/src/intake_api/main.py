"""Intake API: receives patient intake records and stores PHI safely.

Every PHI field is envelope-encrypted before it reaches the database, every
read/write is audited, and nothing identifying ever reaches logs, metrics or
traces.
"""

# NOTE: no `from __future__ import annotations` here: FastAPI must resolve the
# locally-defined Annotated dependency aliases (DB, Actor) at runtime.
import base64
import logging
import uuid
from collections.abc import Iterator
from datetime import date
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from pydantic import BaseModel, EmailStr, Field, field_validator
from sqlalchemy import select, text
from sqlalchemy.orm import Session, sessionmaker

from .crypto import DecryptionError, FieldEncryptor, KeyProvider, KmsKeyProvider, LocalKeyProvider, aad_for
from .db import build_engine, get_session, session_factory
from .models import Patient, PhiAccessLog
from .observability import DECRYPT_FAILURES, PHI_ACCESS, instrument
from .phi_logging import configure_logging
from .settings import Settings

log = logging.getLogger("intake_api")


# --- Schemas -------------------------------------------------------------------
class PatientIn(BaseModel):
    external_ref: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=200)
    date_of_birth: date
    email: EmailStr | None = None
    zip_code: str | None = Field(default=None, pattern=r"^\d{5}(-\d{4})?$")

    @field_validator("date_of_birth")
    @classmethod
    def not_future(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("date_of_birth cannot be in the future")
        return v


class PatientOut(BaseModel):
    id: str
    external_ref: str
    name: str
    date_of_birth: date
    email: str | None
    zip3: str | None


class PatientCreated(BaseModel):
    id: str


# --- App factory -----------------------------------------------------------------
def build_encryptor(settings: Settings) -> FieldEncryptor:
    provider: KeyProvider
    if settings.phi_kms_key_id:
        provider = KmsKeyProvider(settings.phi_kms_key_id)
    else:
        master = (
            base64.b64decode(settings.local_master_key_b64)
            if settings.local_master_key_b64
            else b"local-dev-master-key-0000000000!"
        )
        provider = LocalKeyProvider(master)
    return FieldEncryptor(provider, settings.blind_index_key)


def create_app(
    settings: Settings | None = None,
    sessions: sessionmaker[Session] | None = None,
    encryptor: FieldEncryptor | None = None,
) -> FastAPI:
    settings = settings or Settings()
    configure_logging(settings.log_level)
    if sessions is None:
        sessions = session_factory(build_engine(settings))
    encryptor = encryptor or build_encryptor(settings)

    app = FastAPI(
        title="Meridian Intake API",
        version="1.0.0",
        docs_url=None if settings.deploy_env == "prod" else "/docs",
    )
    instrument(app)

    def db() -> Iterator[Session]:
        yield from get_session(sessions)

    DB = Annotated[Session, Depends(db)]

    def actor(x_actor: Annotated[str | None, Header()] = None) -> str:
        # In production this is the authenticated principal from the JWT
        # validated at the ALB/OIDC layer; header kept simple for the demo.
        if not x_actor:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing actor")
        return x_actor

    Actor = Annotated[str, Depends(actor)]

    def audit(session: Session, request: Request, who: str, action: str, resource_id: str) -> None:
        session.add(
            PhiAccessLog(
                actor=who,
                action=action,
                resource_type="patient",
                resource_id=resource_id,
                request_id=request.headers.get("x-request-id", str(uuid.uuid4())),
            )
        )
        PHI_ACCESS.labels(action, "service" if who.startswith("svc:") else "user").inc()

    @app.get("/healthz", include_in_schema=False)
    def healthz(session: DB) -> dict[str, str]:
        session.execute(text("SELECT 1"))
        return {"status": "ok"}

    @app.post("/v1/patients", status_code=status.HTTP_201_CREATED, response_model=PatientCreated)
    def create_patient(body: PatientIn, request: Request, session: DB, who: Actor) -> PatientCreated:
        existing = session.scalar(select(Patient).where(Patient.external_ref == body.external_ref))
        if existing:
            # Idempotent create: same external_ref returns the same id.
            return PatientCreated(id=existing.id)

        pid = str(uuid.uuid4())
        p = Patient(
            id=pid,
            external_ref=body.external_ref,
            name_enc=encryptor.encrypt(body.name, aad=aad_for("patients", "name", pid)),
            dob_enc=encryptor.encrypt(body.date_of_birth.isoformat(), aad=aad_for("patients", "dob", pid)),
            email_enc=encryptor.encrypt(body.email, aad=aad_for("patients", "email", pid)) if body.email else None,
            email_bidx=encryptor.blind_index(body.email) if body.email else None,
            zip3=body.zip_code[:3] if body.zip_code else None,
            birth_year=body.date_of_birth.year,
        )
        session.add(p)
        audit(session, request, who, "create", pid)
        log.info("patient created", extra={"patient_id": pid})
        return PatientCreated(id=pid)

    @app.get("/v1/patients/{patient_id}", response_model=PatientOut)
    def get_patient(patient_id: str, request: Request, session: DB, who: Actor) -> PatientOut:
        p = session.get(Patient, patient_id)
        if not p:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "not found")
        try:
            out = PatientOut(
                id=p.id,
                external_ref=p.external_ref,
                name=encryptor.decrypt(p.name_enc, aad=aad_for("patients", "name", p.id)),
                date_of_birth=date.fromisoformat(encryptor.decrypt(p.dob_enc, aad=aad_for("patients", "dob", p.id))),
                email=encryptor.decrypt(p.email_enc, aad=aad_for("patients", "email", p.id)) if p.email_enc else None,
                zip3=p.zip3,
            )
        except DecryptionError:
            DECRYPT_FAILURES.inc()
            log.error("decrypt failure", extra={"patient_id": p.id})
            raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, "record integrity error") from None
        audit(session, request, who, "read", p.id)
        return out

    @app.get("/v1/patients", response_model=list[PatientCreated])
    def find_by_email(email: EmailStr, request: Request, session: DB, who: Actor) -> list[PatientCreated]:
        rows = session.scalars(select(Patient).where(Patient.email_bidx == encryptor.blind_index(email))).all()
        for r in rows:
            audit(session, request, who, "search", r.id)
        return [PatientCreated(id=r.id) for r in rows]

    return app


def app() -> FastAPI:  # uvicorn --factory intake_api.main:app
    return create_app()
