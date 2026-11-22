"""Least-privilege guarantees, verified against a REAL Postgres.

Runs the admin task's SQL (roles -> migrations -> grants), then proves what
each runtime role can and cannot do, and runs the API end to end as the
restricted `intake_api` role. Skipped unless TEST_DATABASE_URL points at
Postgres (CI provides one; locally: `docker compose up postgres`).
"""

import os
from urllib.parse import urlsplit

import psycopg
import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient

from intake_api.admin import grant_statements, role_statements
from intake_api.main import create_app
from intake_api.settings import Settings

URL = os.getenv("TEST_DATABASE_URL", "")
pytestmark = [
    pytest.mark.skipif(not URL.startswith("postgresql"), reason="needs TEST_DATABASE_URL (Postgres)"),
    pytest.mark.usefixtures("provisioned"),
]

ROLE_PASSWORD = "test-only-password"  # noqa: S105 (throwaway CI database)
ROLES = ("intake_api", "dr_verifier")


def _conn_kwargs(user: str | None = None, password: str | None = None) -> dict:
    u = urlsplit(URL.replace("+psycopg", ""))
    return {
        "host": u.hostname,
        "port": u.port or 5432,
        "dbname": u.path.lstrip("/"),
        "user": user or u.username,
        "password": password if user else u.password,
        "autocommit": True,
    }


@pytest.fixture(scope="module")
def provisioned():
    owner = urlsplit(URL).username
    with psycopg.connect(**_conn_kwargs()) as c:
        c.execute("DROP SCHEMA public CASCADE")
        c.execute("CREATE SCHEMA public")
        for r in ROLES:
            if c.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (r,)).fetchone():
                c.execute(f"DROP OWNED BY {r}")
                c.execute(f"DROP ROLE {r}")
        for _ in range(2):  # the admin task must be idempotent
            for stmt in role_statements(*ROLES):
                c.execute(stmt)
        for r in ROLES:  # password login only for this test (production uses IAM tokens)
            c.execute(f"ALTER ROLE {r} PASSWORD '{ROLE_PASSWORD}'")

    old = os.environ.get("DATABASE_URL")
    os.environ["DATABASE_URL"] = URL
    cfg = Config(os.path.join(os.path.dirname(__file__), "..", "alembic.ini"))
    cfg.set_main_option("script_location", os.path.join(os.path.dirname(__file__), "..", "migrations"))
    command.upgrade(cfg, "head")

    with psycopg.connect(**_conn_kwargs()) as c:
        for _ in range(2):
            for stmt in grant_statements(owner, *ROLES):
                c.execute(stmt)

    yield owner

    if old is None:
        os.environ.pop("DATABASE_URL", None)
    else:
        os.environ["DATABASE_URL"] = old
    with psycopg.connect(**_conn_kwargs()) as c:  # leave a clean DB for test_migrations
        c.execute("DROP SCHEMA public CASCADE")
        c.execute("CREATE SCHEMA public")
        for r in ROLES:
            c.execute(f"DROP OWNED BY {r}")
            c.execute(f"DROP ROLE {r}")


def _run(user: str | None, sql: str) -> None:
    kwargs = _conn_kwargs(user, ROLE_PASSWORD) if user else _conn_kwargs()
    with psycopg.connect(**kwargs) as c:
        c.execute(sql)


PATIENT = (
    "INSERT INTO patients (id, external_ref, name_enc, dob_enc, created_at, updated_at) "
    "VALUES ('p1', 'e1', 'x', 'y', now(), now())"
)
AUDIT = "INSERT INTO phi_access_log VALUES ('a1', 'user:x', 'read', 'patient', 'p1', 'r1', now())"


@pytest.mark.parametrize(
    ("user", "sql"),
    [
        ("intake_api", PATIENT),
        ("intake_api", "SELECT * FROM patients"),
        ("intake_api", AUDIT),
        ("dr_verifier", "SELECT count(*) FROM patients"),
    ],
)
def test_allowed(user, sql):
    _run(user, sql)


DENIED = {
    "audit log is append-only for the app (update)": ("intake_api", "UPDATE phi_access_log SET actor = 'forged'"),
    "audit log is append-only for the app (delete)": ("intake_api", "DELETE FROM phi_access_log"),
    "app has no DELETE": ("intake_api", "DELETE FROM patients"),
    "app has no DDL": ("intake_api", "DROP TABLE encounters"),
    "trigger blocks even the schema owner": (None, "UPDATE phi_access_log SET actor = 'forged'"),
    "verifier is read-only": ("dr_verifier", "INSERT INTO encounters VALUES ('x', 'p1', 'lab', NULL, now(), now())"),
}


@pytest.mark.parametrize(("user", "sql"), list(DENIED.values()), ids=list(DENIED))
def test_denied(user, sql):
    with pytest.raises(psycopg.Error):
        _run(user, sql)


def test_api_end_to_end_as_least_privilege_role():
    u = urlsplit(URL)
    app_url = f"postgresql+psycopg://intake_api:{ROLE_PASSWORD}@{u.hostname}:{u.port or 5432}{u.path}"
    client = TestClient(create_app(Settings(deploy_env="test", database_url=app_url)))
    h = {"x-actor": "user:e2e"}
    body = {
        "external_ref": "e2e-1",
        "name": "Avery Testwell",
        "date_of_birth": "1980-05-01",
        "email": "avery@example.com",
        "zip_code": "02139",
    }
    assert client.get("/healthz").json() == {"status": "ok"}
    pid = client.post("/v1/patients", json=body, headers=h).json()["id"]
    assert client.get(f"/v1/patients/{pid}", headers=h).json()["name"] == "Avery Testwell"
    assert client.get("/v1/patients", params={"email": "AVERY@example.com"}, headers=h).json() == [{"id": pid}]
