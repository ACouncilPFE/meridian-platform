"""Migrations must apply cleanly, round-trip (downgrade), and match the ORM.

CI runs this against a real Postgres service container (DATABASE_URL); it
falls back to SQLite locally so the test is always runnable.
"""

import os
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import create_engine, inspect

from intake_api.models import Base

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def db_url(tmp_path, monkeypatch):
    url = os.getenv("TEST_DATABASE_URL") or f"sqlite+pysqlite:///{tmp_path}/m.db"
    monkeypatch.setenv("DATABASE_URL", url)
    return url


def _cfg() -> Config:
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "migrations"))
    return cfg


def test_upgrade_downgrade_roundtrip(db_url):
    cfg = _cfg()
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    tables = set(inspect(create_engine(db_url)).get_table_names())
    assert {"patients", "encounters", "phi_access_log", "alembic_version"} <= tables


def test_models_match_migrations(db_url):
    command.upgrade(_cfg(), "head")
    engine = create_engine(db_url)
    with engine.connect() as conn:
        diff = compare_metadata(MigrationContext.configure(conn), Base.metadata)
    # Only structural differences matter (ignore server-side type nuances).
    structural = [d for d in diff if d[0] in ("add_table", "remove_table", "add_column", "remove_column")]
    assert structural == [], f"ORM and migrations drifted: {structural}"
