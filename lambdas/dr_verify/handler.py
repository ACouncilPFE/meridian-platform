"""DR drill verification Lambda (invoked by the Step Functions restore drill).

Checks that a freshly restored Aurora cluster is actually usable, measures
RTO/RPO, and emits the results as OpenTelemetry metrics. The ADOT Lambda
layer's collector remote-writes them to Amazon Managed Prometheus, where the
`DRDrillFailed` / `DRDrillRPOBreached` / `DRDrillStale` alerts evaluate them.

Checks:
  1. Can connect with IAM auth as the read-only dr_verifier role
  2. Expected tables exist
  3. Schema is at the expected Alembic head (restore didn't predate a migration)
  4. Core tables are non-empty and the audit log is still append-only
"""

from __future__ import annotations

import logging
import os
from datetime import UTC, datetime

log = logging.getLogger()
log.setLevel(logging.INFO)

# PITR restore: data loss window = drill start - latest restorable time.
RPO_TARGET_SECONDS = int(os.getenv("RPO_TARGET_SECONDS", str(15 * 60)))
RTO_TARGET_SECONDS = int(os.getenv("RTO_TARGET_SECONDS", str(60 * 60)))


def _parse(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def evaluate(checks: dict[str, bool], restore_point_at: str, drill_started_at: str, now: datetime) -> dict:
    """Pure function: all decision logic, unit-testable without AWS."""
    rpo = (_parse(drill_started_at) - _parse(restore_point_at)).total_seconds()
    rto = (now - _parse(drill_started_at)).total_seconds()
    passed = all(checks.values()) and rpo <= RPO_TARGET_SECONDS and rto <= RTO_TARGET_SECONDS
    return {
        "passed": passed,
        "checks": checks,
        "rpo_seconds": round(rpo),
        "rto_seconds": round(rto),
        "rpo_target_seconds": RPO_TARGET_SECONDS,
        "rto_target_seconds": RTO_TARGET_SECONDS,
    }


def run_checks(conn, expected_tables: list[str], expected_head: str | None) -> dict[str, bool]:
    cur = conn.cursor()
    cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")
    present = {r[0] for r in cur.fetchall()}
    checks = {f"table:{t}": t in present for t in expected_tables}

    if "alembic_version" in present:
        cur.execute("SELECT version_num FROM alembic_version")
        head = cur.fetchone()
        checks["migration_head"] = bool(head) and (expected_head is None or head[0] == expected_head)

    if "patients" in present:
        cur.execute("SELECT EXISTS (SELECT 1 FROM patients LIMIT 1)")
        checks["patients_nonempty"] = bool(cur.fetchone()[0])

    cur.execute("SELECT 1 FROM pg_trigger WHERE tgname = 'phi_access_log_no_mutation'")
    checks["audit_log_immutable"] = cur.fetchone() is not None
    return checks


def _emit_metrics(result: dict, cluster: str) -> None:
    try:
        from opentelemetry import metrics
    except ImportError:  # layer not attached (local runs)
        return
    meter = metrics.get_meter("dr_drill")
    attrs = {"cluster": cluster}
    for name, value in (
        ("dr_drill_success", 1 if result["passed"] else 0),
        ("dr_drill_rpo_seconds", result["rpo_seconds"]),
        ("dr_drill_rto_seconds", result["rto_seconds"]),
        ("dr_drill_last_run_timestamp_seconds", int(datetime.now(UTC).timestamp())),
    ):
        meter.create_gauge(name).set(value, attrs)
    provider = metrics.get_meter_provider()
    if hasattr(provider, "force_flush"):
        provider.force_flush()


def _connect(endpoint: str):
    import boto3
    import psycopg

    token = boto3.client("rds").generate_db_auth_token(DBHostname=endpoint, Port=5432, DBUsername="dr_verifier")
    return psycopg.connect(
        host=endpoint, port=5432, dbname=os.environ["DB_NAME"], user="dr_verifier",
        password=token, sslmode="require", connect_timeout=10,
    )


def lambda_handler(event, _context):
    expected_tables = [t for t in os.environ.get("EXPECTED_TABLES", "").split(",") if t]
    try:
        with _connect(event["endpoint"]) as conn:
            checks = run_checks(conn, expected_tables, os.getenv("EXPECTED_ALEMBIC_HEAD"))
    except Exception as exc:
        log.exception("connection or check failure")
        checks = {"connect": False, "error": False}
        log.error("drill error: %s", type(exc).__name__)

    result = evaluate(checks, event["restore_point_at"], event["drill_started_at"], datetime.now(UTC))
    _emit_metrics(result, event.get("source_cluster", "unknown"))
    log.info("drill result", extra={"result": result})
    return result
