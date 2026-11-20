"""One-off database administration task (runs as an ECS task, never in the API).

    python -m intake_api.admin

Separation of duties:
  * This task is the ONLY thing that uses the Aurora master credential (read
    from Secrets Manager by a dedicated task definition, see the
    `db-admin-task` Terraform module). The API never sees it.
  * It creates the IAM-authenticated login roles, runs Alembic migrations as
    the schema owner, then grants each runtime role the minimum it needs.
  * The API connects as `intake_api` with a 15-minute IAM token; the DR
    drill connects as read-only `dr_verifier`.

Idempotent: safe to run on every deploy.
"""

from __future__ import annotations

import logging
import os
import re
from urllib.parse import quote

from .phi_logging import configure_logging

log = logging.getLogger("intake_api.admin")

ROLE_NAME = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
RDS_CA_BUNDLE = "/etc/ssl/certs/rds-global-bundle.pem"


def _ident(name: str) -> str:
    if not ROLE_NAME.match(name):
        raise ValueError(f"invalid role name {name!r}")
    return name


def role_statements(app_role: str, verifier_role: str) -> list[str]:
    """Create login roles (IAM auth on RDS). Runs before migrations."""
    # Role names can't be bind parameters in DDL; they are validated against
    # ROLE_NAME by _ident() instead, which is what the S608 suppressions rely on.
    out: list[str] = []
    for role in (_ident(app_role), _ident(verifier_role)):
        out.append(
            f"DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') "  # noqa: S608
            f"THEN CREATE ROLE {role} LOGIN; END IF; END $$"
        )
        # rds_iam only exists on RDS/Aurora; skip silently elsewhere (local Postgres).
        out.append(
            f"DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_iam') "  # noqa: S608
            f"THEN EXECUTE 'GRANT rds_iam TO {role}'; END IF; END $$"
        )
    return out


def grant_statements(owner: str, app_role: str, verifier_role: str) -> list[str]:
    """Least-privilege grants. Runs after migrations so tables exist."""
    owner, app, ver = _ident(owner), _ident(app_role), _ident(verifier_role)
    return [
        f"GRANT USAGE ON SCHEMA public TO {app}, {ver}",
        # API: read/write clinical tables, append-only audit log, no DDL, no DELETE.
        f"GRANT SELECT, INSERT, UPDATE ON patients, encounters TO {app}",
        f"GRANT INSERT ON phi_access_log TO {app}",
        f"REVOKE UPDATE, DELETE, TRUNCATE ON phi_access_log FROM {app}",
        f"GRANT SELECT ON alembic_version TO {app}",
        # DR verifier: read-only everywhere, used only against restored drill clusters.
        f"GRANT SELECT ON ALL TABLES IN SCHEMA public TO {ver}",
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT SELECT ON TABLES TO {ver}",
    ]


def admin_url(host: str, db: str, user: str, password: str) -> str:
    return (
        f"postgresql+psycopg://{quote(user)}:{quote(password, safe='')}@{host}:5432/{db}"
        f"?sslmode=verify-full&sslrootcert={RDS_CA_BUNDLE}"
    )


def main() -> None:
    configure_logging()
    import psycopg
    from alembic import command
    from alembic.config import Config

    host = os.environ["DB_HOST"]
    db = os.environ.get("DB_NAME", "app")
    owner = os.environ.get("DB_ADMIN_USER", "platform_admin")
    password = os.environ["DB_MASTER_PASSWORD"]
    app_role = os.environ.get("APP_DB_USER", "intake_api")
    verifier_role = os.environ.get("VERIFIER_DB_USER", "dr_verifier")

    def connect() -> psycopg.Connection:
        # Keyword args (not a DSN string) so any character in the password is safe.
        return psycopg.connect(
            host=host,
            dbname=db,
            user=owner,
            password=password,
            sslmode="verify-full",
            sslrootcert=RDS_CA_BUNDLE,
            connect_timeout=60,
            autocommit=True,
        )

    with connect() as conn:
        for stmt in role_statements(app_role, verifier_role):
            conn.execute(stmt)
    log.info("login roles ensured")

    # Migrations run as the schema owner (env.py reads DATABASE_URL).
    os.environ["DATABASE_URL"] = admin_url(host, db, owner, password)
    os.environ.pop("DB_IAM_AUTH", None)
    command.upgrade(Config("/app/alembic.ini"), "head")
    log.info("migrations at head")

    with connect() as conn:
        for stmt in grant_statements(owner, app_role, verifier_role):
            conn.execute(stmt)
    log.info("grants applied")


if __name__ == "__main__":
    main()
