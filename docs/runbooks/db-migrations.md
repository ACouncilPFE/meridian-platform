# Runbook: Database migrations

## Rules

1. **Expand/contract.** Release N adds; release N+1 (or later) removes. The previous app version must always work against the current schema, because that is what makes `make rollback` safe.
2. **Every migration has a working `downgrade()`.** CI runs upgrade → downgrade → upgrade against real Postgres.
3. **Lock safety.** `env.py` sets `lock_timeout = 5s`. If a migration can't get its lock in 5s, it fails rather than queueing behind traffic and taking the API down.
4. **Big tables:** create indexes `CONCURRENTLY` (outside a transaction), add constraints `NOT VALID` then `VALIDATE`, and backfill in batches from a job rather than in the migration.
5. **Encrypted columns can't be backfilled with SQL.** Use a one-off ECS task under the intake-api role.

## Patterns

| Change | Release N (expand) | Release N+1 (contract) |
|---|---|---|
| Add required column | add nullable + app writes it + backfill | `SET NOT NULL` via `NOT VALID` check + validate |
| Rename column | add new, dual-write, backfill, read new | drop old |
| Drop column | stop reading/writing it | drop |
| Change type | add new column + dual-write | swap, drop old |

## How migrations run

- **Prod:** `deploy.yml` runs `alembic upgrade head` as a one-off Fargate task using the release's image digest, *before* Terraform shifts traffic. A failure aborts the deploy with zero user impact.
- **Preview envs:** the same script, against the PR's own cluster.
- **Locally:** the `migrate` service in docker-compose.

## If a migration fails in prod

1. The deploy has already stopped and the old version is still serving.
2. Check the task logs (`/ecs/prod/intake-api`, stream prefix `app`).
3. Lock timeout: retry off-peak, or restructure the migration (see rule 4).
4. Never hand-edit `alembic_version`. Fix forward with a new revision.
