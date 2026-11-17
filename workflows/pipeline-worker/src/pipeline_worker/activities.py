"""Temporal activities for the de-identified export pipeline.

Least privilege by construction: this worker reads only the columns needed
for Safe Harbor output (ids, zip3, birth_year, encounter type/time) from the
Aurora READ REPLICA. It never selects *_enc columns and has no kms:Decrypt
on the PHI key, so even a bug here can't exfiltrate direct identifiers.
"""

from __future__ import annotations

import gzip
import json
import os
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from temporalio import activity

from .deidentify import SourceEncounter, SourcePatient, deidentify


@dataclass
class ExtractRequest:
    after_encounter_id: str | None
    since: str  # ISO timestamp watermark
    limit: int = 5000


@dataclass
class ExtractResult:
    rows: list[dict]  # already de-identified; raw rows never leave the activity
    last_encounter_id: str | None
    count: int


@dataclass
class StageRequest:
    run_id: str
    batch_no: int
    rows: list[dict]


@dataclass
class LoadRequest:
    run_id: str
    s3_prefix: str


class SourceRepo(Protocol):
    def fetch(self, after_id: str | None, since: datetime, limit: int) -> list[tuple[SourcePatient, SourceEncounter]]: ...


class ObjectStore(Protocol):
    def put(self, key: str, body: bytes) -> None: ...


class Warehouse(Protocol):
    def copy_into(self, s3_prefix: str) -> int: ...


class ExportActivities:
    """Activities hold their dependencies so tests inject fakes."""

    def __init__(self, repo: SourceRepo, store: ObjectStore, warehouse: Warehouse, pseudonym_secret: bytes):
        self._repo = repo
        self._store = store
        self._wh = warehouse
        self._secret = pseudonym_secret

    @activity.defn
    def extract_and_deidentify(self, req: ExtractRequest) -> ExtractResult:
        # De-identification happens INSIDE the activity so raw source rows are
        # never written to Temporal history (which is persisted and replicated).
        pairs = self._repo.fetch(req.after_encounter_id, datetime.fromisoformat(req.since), req.limit)
        rows = [deidentify(p, e, self._secret).as_row() for p, e in pairs]
        last = pairs[-1][1].id if pairs else None
        activity.logger.info("extracted batch", extra={"count": len(rows)})
        return ExtractResult(rows=rows, last_encounter_id=last, count=len(rows))

    @activity.defn
    def stage_batch(self, req: StageRequest) -> str:
        key = f"deidentified/encounters/run={req.run_id}/batch-{req.batch_no:05d}.json.gz"
        body = gzip.compress("\n".join(json.dumps(r) for r in req.rows).encode())
        self._store.put(key, body)
        return key

    @activity.defn
    def load_warehouse(self, req: LoadRequest) -> int:
        loaded = self._wh.copy_into(req.s3_prefix)
        activity.logger.info("loaded into snowflake", extra={"rows": loaded})
        return loaded


# --- Real adapters ----------------------------------------------------------
class PostgresRepo:
    SQL = """
        SELECT p.id, p.zip3, p.birth_year, e.id, e.patient_id, e.encounter_type, e.occurred_at
        FROM encounters e JOIN patients p ON p.id = e.patient_id
        WHERE e.created_at >= %(since)s AND (%(after)s::text IS NULL OR e.id > %(after)s)
        ORDER BY e.id
        LIMIT %(limit)s
    """

    def __init__(self, dsn: str):
        self._dsn = dsn

    def fetch(self, after_id, since, limit):
        import psycopg

        with psycopg.connect(self._dsn) as conn, conn.cursor() as cur:
            cur.execute("SET TRANSACTION READ ONLY")
            cur.execute(self.SQL, {"since": since, "after": after_id, "limit": limit})
            return [
                (SourcePatient(r[0], r[1], r[2]), SourceEncounter(r[3], r[4], r[5], r[6]))
                for r in cur.fetchall()
            ]


class S3Store:
    def __init__(self, bucket: str):
        import boto3

        self._s3 = boto3.client("s3")
        self._bucket = bucket

    def put(self, key: str, body: bytes) -> None:
        self._s3.put_object(Bucket=self._bucket, Key=key, Body=body, ServerSideEncryption="aws:kms")


class SnowflakeWarehouse:
    def __init__(self, stage: str = "RAW.DEIDENTIFIED_STAGE", table: str = "RAW.ENCOUNTERS"):
        self._stage = stage
        self._table = table

    def copy_into(self, s3_prefix: str) -> int:
        import snowflake.connector  # key-pair auth; private key from Secrets Manager

        conn = snowflake.connector.connect(
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            user=os.environ["SNOWFLAKE_USER"],
            private_key_file=os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"],
            role=os.environ.get("SNOWFLAKE_ROLE", "MERIDIAN_ANALYTICS_LOADER"),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "MERIDIAN_ANALYTICS_LOAD_WH"),
            database=os.environ.get("SNOWFLAKE_DATABASE", "MERIDIAN_ANALYTICS"),
        )
        try:
            cur = conn.cursor()
            # COPY is idempotent per file (Snowflake load metadata), so
            # Temporal retries can't double-load a batch.
            cur.execute(
                f"COPY INTO {self._table} FROM @{self._stage}/{s3_prefix.removeprefix('deidentified/')} "  # noqa: S608
                "FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE"
            )
            return sum(int(row[3]) for row in cur.fetchall() if len(row) > 3 and str(row[3]).isdigit())
        finally:
            conn.close()
