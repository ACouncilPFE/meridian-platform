import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from intake_api.crypto import FieldEncryptor, LocalKeyProvider
from intake_api.main import create_app
from intake_api.models import Base, Patient, PhiAccessLog
from intake_api.settings import Settings

HEADERS = {"x-actor": "user:clinician-42"}
BODY = {
    "external_ref": "ext-001",
    "name": "Jane Q. Public",
    "date_of_birth": "1984-03-09",
    "email": "jane@example.com",
    "zip_code": "02139",
}


@pytest.fixture
def sessions():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine, expire_on_commit=False)


@pytest.fixture
def client(sessions):
    enc = FieldEncryptor(LocalKeyProvider(b"m" * 32), b"b" * 32)
    app = create_app(Settings(deploy_env="test"), sessions=sessions, encryptor=enc)
    return TestClient(app)


def test_create_and_read_roundtrip(client):
    r = client.post("/v1/patients", json=BODY, headers=HEADERS)
    assert r.status_code == 201
    pid = r.json()["id"]

    r = client.get(f"/v1/patients/{pid}", headers=HEADERS)
    assert r.status_code == 200
    data = r.json()
    assert data["name"] == BODY["name"]
    assert data["date_of_birth"] == BODY["date_of_birth"]
    assert data["zip3"] == "021"


def test_phi_never_stored_in_clear(client, sessions):
    pid = client.post("/v1/patients", json=BODY, headers=HEADERS).json()["id"]
    with sessions() as s:
        row = s.get(Patient, pid)
        stored = " ".join(str(v) for v in vars(row).values())
    assert "Jane" not in stored
    assert "jane@example.com" not in stored
    assert "1984-03-09" not in stored
    assert row.birth_year == 1984


def test_create_is_idempotent(client):
    a = client.post("/v1/patients", json=BODY, headers=HEADERS).json()["id"]
    b = client.post("/v1/patients", json=BODY, headers=HEADERS).json()["id"]
    assert a == b


def test_every_phi_access_is_audited(client, sessions):
    pid = client.post("/v1/patients", json=BODY, headers=HEADERS).json()["id"]
    client.get(f"/v1/patients/{pid}", headers=HEADERS)
    client.get("/v1/patients", params={"email": "JANE@example.com"}, headers=HEADERS)
    with sessions() as s:
        actions = [r.action for r in s.scalars(select(PhiAccessLog).order_by(PhiAccessLog.occurred_at))]
    assert actions == ["create", "read", "search"]


def test_search_by_blind_index(client):
    pid = client.post("/v1/patients", json=BODY, headers=HEADERS).json()["id"]
    r = client.get("/v1/patients", params={"email": "Jane@Example.com"}, headers=HEADERS)
    assert r.json() == [{"id": pid}]


def test_requires_actor(client):
    assert client.post("/v1/patients", json=BODY).status_code == 401


def test_rejects_future_dob(client):
    bad = {**BODY, "date_of_birth": "2999-01-01"}
    assert client.post("/v1/patients", json=bad, headers=HEADERS).status_code == 422


def test_metrics_exposed_without_identifiers(client):
    pid = client.post("/v1/patients", json=BODY, headers=HEADERS).json()["id"]
    client.get(f"/v1/patients/{pid}", headers=HEADERS)
    body = client.get("/metrics").text
    assert 'route="/v1/patients/{patient_id}"' in body
    assert pid not in body
    assert "phi_access_total" in body


def test_healthz(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_prod_settings_refuse_local_keys():
    with pytest.raises(ValueError):
        Settings(deploy_env="prod", phi_kms_key_id=None)
    with pytest.raises(ValueError):
        Settings(deploy_env="prod", phi_kms_key_id="k", db_iam_auth=True, local_master_key_b64="eA==")
