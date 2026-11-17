# Runbook: intake-api error budget burn

**Alerts:** `IntakeApiErrorBudgetFastBurn` (critical, 2% of monthly budget in 1h), `IntakeApiErrorBudgetSlowBurn` (warning)

## Triage (first 5 minutes)

1. **Grafana → intake-api: SLO & golden signals.** Is it one route or all routes? When did it start?
2. **Did something change?** Check the deploy annotation and recent `deploy` workflow runs.
   - It started within 15 min of a deploy → **roll back first, debug later**: `make rollback ENV=prod SERVICE=intake-api`. This is safe because migrations are expand-only.
3. **Dependencies:**
   - Aurora: replica lag, connections, CPU (Performance Insights). Failover in progress?
   - KMS: throttling shows as decrypt latency or 5xx on GET. Check `phi_decrypt_failures_total`.
4. **Traces:** in the latency panel, click an exemplar to jump to a Tempo trace of a failing request.

## Common causes

| Symptom | Likely cause | Fix |
|---|---|---|
| All routes 5xx, `/healthz` failing | DB unreachable or IAM token failure | Check SG changes, RDS events, and the `rds-db:connect` policy |
| Spike during Aurora failover | Connections to the old writer | Self-heals in about 60s (`pool_pre_ping`). If not, force a new deployment. |
| Only GET by id fails | KMS throttling or key policy drift | Check CloudTrail for `AccessDenied` on Decrypt. Escalate to security if the policy changed. |
| 5xx after deploy | Code regression | Roll back |

## Never

- Don't increase log verbosity to dump request bodies. Request bodies contain PHI.
- Don't silence the alert without an incident ticket.
