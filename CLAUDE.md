# CLAUDE.md: working agreement for AI agents in this repo

This repo is developed AI-natively: Claude Code drafts, refactors, reviews, and helps operate it. The rules below keep a human accountable for every change that touches PHI, IAM, or production data. **Read this file before making changes.**

## Context

- Regulated environment (HIPAA, SOC 2). Treat anything under `services/`, `workflows/`, and `terraform/` as handling PHI or protecting it.
- Architecture and rationale are in `README.md` and `docs/adr/`. Read the relevant ADR before changing a design.

## Commands

| Task | Command |
|---|---|
| All tests + rule tests + dashboard drift | `make test` |
| API tests only | `cd services/intake-api && pytest -q` |
| Lint / format / types | `ruff check . && ruff format --check . && mypy src` |
| Terraform | `make tf-wiring` (offline) and `make tf-check` (fmt + validate). **Never** run `apply` or `destroy`; the demo is deployed by a human via `make demo-up`. |
| Alert rules | `make obs-test` |
| Regenerate dashboards | `make dashboards` (edit `build_dashboards.py`, never the JSON) |

## Definition of done (agent must verify, not assume)

1. `make test` passes locally, and you have read the output rather than inferred it.
2. New behavior has tests. Bug fixes include a test that fails before the fix.
3. New endpoints and jobs have metrics, an alert rule with a promtool test, and a runbook link.
4. Migrations are expand-only, have a working `downgrade()`, and pass `test_migrations.py`.
5. The PR description lists which parts were AI-drafted and how each was verified.

## Hard rules

- **No real PHI anywhere**: not in tests, fixtures, logs, prompts, or commit messages. Use `scripts/seed_synthetic.py`-style generated data only.
- Never log request bodies or add identifiers (patient ids, emails, raw paths) to metric labels or span attributes.
- Never weaken `crypto.py`, `phi_logging.py`, `deidentify.py`, KMS key policies, IAM trust policies, security groups, or `.checkov.yml` skips without stating it explicitly in the PR summary. These paths require security CODEOWNER review.
- Don't add fields to `DeidentifiedEncounter`. The allow-list test exists to force a privacy review.
- No credentials in code. AWS access is via OIDC roles; app secrets come from Secrets Manager.
- Don't run commands against AWS accounts, Snowflake, or Temporal Cloud. Local stack only (`make up`).

## Always ask a human first

- Any Terraform change that would **replace or destroy** a stateful resource (Aurora, DynamoDB, KMS, S3, backup vaults).
- Any change to data retention, backup schedules, or vault lock settings.
- Destructive migrations (drop or rename), even when "unused".
- Changing alert thresholds or silencing alerts.

## Validation & oversight

AI output is a draft until verified. For anything non-trivial, the agent should:
- State its assumptions and what it did **not** verify.
- Prefer small, reviewable diffs over sweeping rewrites.
- Use a fresh review pass (a separate agent or human) for security-sensitive diffs. The author doesn't grade its own work.
- When operating (reading dashboards, triaging alerts), recommend actions with evidence. A human executes anything that changes production.
