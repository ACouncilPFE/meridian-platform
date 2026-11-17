from datetime import UTC, datetime

import handler


class FakeCursor:
    def __init__(self, tables, head="0002", nonempty=True, trigger=True):
        self.tables, self.head, self.nonempty, self.trigger = tables, head, nonempty, trigger
        self._last = None

    def execute(self, sql):
        self._last = sql

    def fetchall(self):
        return [(t,) for t in self.tables]

    def fetchone(self):
        if "alembic_version" in self._last:
            return (self.head,)
        if "EXISTS" in self._last:
            return (self.nonempty,)
        if "pg_trigger" in self._last:
            return (1,) if self.trigger else None
        return None


class FakeConn:
    def __init__(self, cur):
        self._cur = cur

    def cursor(self):
        return self._cur


TABLES = ["patients", "encounters", "phi_access_log", "alembic_version"]


def test_healthy_restore_passes():
    checks = handler.run_checks(FakeConn(FakeCursor(TABLES)), TABLES, "0002")
    assert all(checks.values())
    r = handler.evaluate(checks, "2026-11-15T07:55:00Z", "2026-11-15T08:00:00Z", datetime(2026, 11, 15, 8, 40, tzinfo=UTC))
    assert r["passed"] and r["rpo_seconds"] == 5 * 60 and r["rto_seconds"] == 40 * 60


def test_stale_migration_head_fails():
    checks = handler.run_checks(FakeConn(FakeCursor(TABLES, head="0001")), TABLES, "0002")
    assert checks["migration_head"] is False


def test_missing_audit_trigger_fails():
    checks = handler.run_checks(FakeConn(FakeCursor(TABLES, trigger=False)), TABLES, None)
    assert checks["audit_log_immutable"] is False


def test_rpo_breach_fails_even_if_checks_pass():
    # Latest restorable time an hour behind: continuous backup is stalled.
    r = handler.evaluate({"ok": True}, "2026-11-14T23:00:00Z", "2026-11-15T00:00:00Z", datetime(2026, 11, 15, 0, 10, tzinfo=UTC))
    assert not r["passed"]


def test_rto_breach_fails():
    r = handler.evaluate({"ok": True}, "2026-11-15T00:58:00Z", "2026-11-15T01:00:00Z", datetime(2026, 11, 15, 3, 0, tzinfo=UTC))
    assert not r["passed"]
