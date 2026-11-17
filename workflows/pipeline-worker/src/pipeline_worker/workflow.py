"""DeidentifyExportWorkflow: incremental, resumable PHI -> de-identified export.

Why Temporal instead of a cron + script:
  * Durable progress: a worker crash/redeploy resumes from the last
    completed batch rather than restarting or skipping.
  * Per-step retry policies (DB blips retry fast; Snowflake outages back off).
  * continue_as_new keeps history bounded for arbitrarily large backfills.
  * Full execution history = audit evidence of what was exported, when.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from .activities import ExportActivities, ExtractRequest, LoadRequest, StageRequest

DB_RETRY = RetryPolicy(initial_interval=timedelta(seconds=2), backoff_coefficient=2, maximum_attempts=8)
WAREHOUSE_RETRY = RetryPolicy(initial_interval=timedelta(seconds=30), maximum_interval=timedelta(minutes=10))



@dataclass
class ExportInput:
    since: str
    run_id: str
    after_encounter_id: str | None = None
    batch_no: int = 0
    total_rows: int = 0
    staged_prefix: str | None = None
    batch_size: int = 5000
    batches_per_run: int = 50  # continue_as_new after this many to bound history size


@dataclass
class ExportResult:
    run_id: str
    total_rows: int
    loaded_rows: int
    batches: int = 0
    notes: list[str] = field(default_factory=list)


@workflow.defn
class DeidentifyExportWorkflow:
    def __init__(self) -> None:
        self._progress = {"batch_no": 0, "total_rows": 0}

    @workflow.query
    def progress(self) -> dict:
        return self._progress

    @workflow.run
    async def run(self, inp: ExportInput) -> ExportResult:
        prefix = inp.staged_prefix or f"deidentified/encounters/run={inp.run_id}/"
        after = inp.after_encounter_id
        batch_no = inp.batch_no
        total = inp.total_rows

        for _ in range(inp.batches_per_run):
            extracted = await workflow.execute_activity_method(
                ExportActivities.extract_and_deidentify,
                ExtractRequest(after_encounter_id=after, since=inp.since, limit=inp.batch_size),
                start_to_close_timeout=timedelta(minutes=5),
                retry_policy=DB_RETRY,
            )
            if extracted.count == 0:
                break

            await workflow.execute_activity_method(
                ExportActivities.stage_batch,
                StageRequest(run_id=inp.run_id, batch_no=batch_no, rows=extracted.rows),
                start_to_close_timeout=timedelta(minutes=2),
                retry_policy=DB_RETRY,
            )
            after = extracted.last_encounter_id
            batch_no += 1
            total += extracted.count
            self._progress = {"batch_no": batch_no, "total_rows": total}

            if extracted.count < inp.batch_size:
                break
        else:
            # More work remains: start a fresh run with the cursor carried over.
            workflow.continue_as_new(
                ExportInput(
                    since=inp.since,
                    run_id=inp.run_id,
                    after_encounter_id=after,
                    batch_no=batch_no,
                    total_rows=total,
                    staged_prefix=prefix,
                    batch_size=inp.batch_size,
                    batches_per_run=inp.batches_per_run,
                )
            )

        loaded = 0
        if total > 0:
            loaded = await workflow.execute_activity_method(
                ExportActivities.load_warehouse,
                LoadRequest(run_id=inp.run_id, s3_prefix=prefix),
                start_to_close_timeout=timedelta(minutes=30),
                retry_policy=WAREHOUSE_RETRY,
            )
        return ExportResult(run_id=inp.run_id, total_rows=total, loaded_rows=loaded, batches=batch_no)
