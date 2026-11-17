# Runbook: Disaster recovery (Aurora)

**Targets:** RPO ≤ 15 min in-region (PITR) / ≤ 24h cross-region (daily backup copy) · RTO ≤ 1h

The weekly drill restores the production cluster to its latest restorable time (the same path as §A), so it exercises continuous backup, KMS grants and the restore IAM path end to end. Cross-region recovery points are verified quarterly via §B in a game day.
**Alerts:** `DRDrillFailed` (critical), `DRDrillStale`, `DRDrillRPOBreached`

## Scenario matrix

| Failure | Mechanism | Expected RTO | Action |
|---|---|---|---|
| Writer instance / AZ failure | Aurora automatic failover to a reader | 30 to 60s | None. Verify in Grafana that error budget burn has recovered. |
| Bad deploy / data corruption | PITR to a new cluster | 20 to 40 min | §A |
| Accidental deletion | Deletion protection + final snapshot + AWS Backup (vault-locked) | 30 to 60 min | §A from snapshot |
| Region outage | Cross-region backup copy in us-west-2 | 1 to 4 h | §B |
| Ransomware / malicious admin | Vault Lock: backups can't be deleted early, even by root | as §B | §B + security incident process |

## §A: Point-in-time restore (in-region)

1. Declare an incident and freeze deploys (disable the `deploy` workflow).
2. Pick the restore time: the last known-good moment from audit logs or the deploy timeline in Grafana.
3. Restore to a **new** cluster (never overwrite the original, which is evidence):
   ```bash
   aws rds restore-db-cluster-to-point-in-time \
     --source-db-cluster-identifier meridian-prod-core \
     --db-cluster-identifier meridian-prod-core-restore-$(date +%Y%m%d%H%M) \
     --restore-to-time <ISO8601> --use-latest-restorable-time=false \
     --db-subnet-group-name meridian-prod-core \
     --vpc-security-group-ids <aurora-sg> --kms-key-id alias/meridian-prod/phi
   aws rds create-db-instance --db-instance-identifier <new>-0 \
     --db-cluster-identifier <new> --db-instance-class db.serverless --engine aurora-postgresql
   ```
4. Verify by invoking the DR verify Lambda against the new endpoint (same checks as the weekly drill).
5. Cut over: update `DB_HOST` (Terraform var) to the new cluster, apply via the `deploy` workflow, and confirm the SLO dashboard is green.
6. Import the new cluster into Terraform state, or rename it per the post-incident plan.

## §B: Regional failover (us-west-2)

1. Restore the latest copied recovery point from the `meridian-prod-dr` backup vault (AWS Backup console or `aws backup start-restore-job`).
2. Apply `envs/prod` with `-var region=us-west-2` against a DR workspace (network and services are reproducible from code; only data needs restoring).
3. Point DNS at the DR ALB. Rotate Temporal and Snowflake allow-lists to the DR NAT IPs.
4. Expect data loss up to the last daily copy (RPO ≤ 24h). Notify compliance: this may be a reportable availability event.

## When the drill fails

1. Open the Step Functions execution (link in the alert, or `make` → console). Find the failing state.
2. Common causes: KMS grant missing for the restore role, a leftover `-drill` cluster from a previous failed run, a migration head mismatch (the restore predates the latest migration, which is expected right after a deploy, so re-run the drill), or the subnet group changed.
3. Re-run on demand: GitHub → Actions → `dr-drill` → Run workflow.
4. A failed drill is a SOC 2 A1.3 exception. Record the cause and fix in the drill log.
