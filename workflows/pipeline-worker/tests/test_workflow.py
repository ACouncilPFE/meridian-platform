"""Workflow tests against Temporal's time-skipping test server.

The test server binary is downloaded on first use; if it isn't reachable
(e.g. an offline sandbox) the test is skipped rather than failing. CI runs
it for real.
"""

import gzip
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from temporalio.testing import WorkflowEnvironment
from temporalio.worker import Worker

from pipeline_worker.activities import ExportActivities
from pipeline_worker.deidentify import SourceEncounter, SourcePatient
from pipeline_worker.workflow import DeidentifyExportWorkflow, ExportInput


class FakeRepo:
    def __init__(self, n):
        base = datetime(2026, 1, 1, tzinfo=UTC)
        self.pairs = [
            (SourcePatient(f"p{i % 7}", "021", 1980), SourceEncounter(f"e{i:06d}", f"p{i % 7}", "lab", base + timedelta(hours=i)))
            for i in range(n)
        ]
        self.calls = 0
        self.fail_first = True

    def fetch(self, after_id, since, limit):  # noqa: ARG002
        self.calls += 1
        if self.fail_first:  # transient DB failure: workflow must retry, not lose progress
            self.fail_first = False
            raise ConnectionError("simulated failover")
        rows = [p for p in self.pairs if after_id is None or p[1].id > after_id]
        return rows[:limit]


class FakeStore:
    def __init__(self):
        self.objects = {}

    def put(self, key, body):
        self.objects[key] = body


class FakeWarehouse:
    def __init__(self, store):
        self.store = store

    def copy_into(self, s3_prefix):
        return sum(len(gzip.decompress(b).splitlines()) for k, b in self.store.objects.items() if k.startswith(s3_prefix))


@pytest.fixture
async def env():
    try:
        e = await WorkflowEnvironment.start_time_skipping()
    except Exception as exc:  # pragma: no cover
        pytest.skip(f"Temporal test server unavailable: {exc}")
    yield e
    await e.shutdown()


@pytest.mark.asyncio
async def test_exports_all_rows_across_batches_and_continue_as_new(env):
    repo, store = FakeRepo(23), FakeStore()
    acts = ExportActivities(repo, store, FakeWarehouse(store), b"s" * 32)

    async with Worker(
        env.client,
        task_queue="test",
        workflows=[DeidentifyExportWorkflow],
        activities=[acts.extract_and_deidentify, acts.stage_batch, acts.load_warehouse],
        activity_executor=ThreadPoolExecutor(4),
    ):
        result = await env.client.execute_workflow(
            DeidentifyExportWorkflow.run,
            # batches_per_run=2 with 23 rows / batch 5 forces continue_as_new
            ExportInput(since="2025-01-01T00:00:00+00:00", run_id="r1", batch_size=5, batches_per_run=2),
            id=f"export-{uuid.uuid4()}",
            task_queue="test",
        )

    assert result.total_rows == 23
    assert result.loaded_rows == 23
    staged = [json.loads(line) for b in store.objects.values() for line in gzip.decompress(b).splitlines()]
    assert len({r["ENCOUNTER_KEY"] for r in staged}) == 23  # no dupes, no gaps
    assert len({r["PATIENT_KEY"] for r in staged}) == 7  # stable pseudonyms per patient
    assert repo.calls > 1  # transient failure was retried
