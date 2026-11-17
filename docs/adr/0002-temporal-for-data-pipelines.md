# ADR-0002: Temporal for data pipelines

**Status:** Accepted

## Context
The nightly de-identified export to Snowflake must be incremental, survive worker restarts and deploys, retry transient failures differently by dependency (DB failover versus a Snowflake outage), and leave an auditable record of what was exported. Options considered: cron + script, Step Functions, Airflow, Temporal.

## Decision
Use Temporal (Temporal Cloud in prod, `temporalio/auto-setup` locally), with workers on the Fargate paved road.

| | Cron + script | Step Functions | Airflow | Temporal |
|---|---|---|---|---|
| Durable resume mid-run | No | Yes | Task-level | Yes, per activity |
| Per-step retry policy | DIY | Yes | Yes | Yes |
| Logic as plain code + unit tests | Yes | No (ASL) | Partial | Yes (time-skipping tests) |
| Unbounded loops / backfills | Yes | 25k event limit | DAG-shaped | `continue_as_new` |
| Fits existing app engineers | Yes | Low | Medium | Yes |

Step Functions is still used where its strengths fit: the DR drill is a short, AWS-API-heavy, infrequent orchestration with no custom code beyond one Lambda.

## Consequences
- Workflow history is persisted, so **raw PHI must never be an activity input or output**. De-identification happens inside the activity, and only Safe Harbor rows cross the boundary.
- Workflow code must be deterministic. That's enforced by the SDK sandbox and covered by tests.
- Temporal Cloud is another BAA vendor. Access uses mTLS certificates from Secrets Manager.
