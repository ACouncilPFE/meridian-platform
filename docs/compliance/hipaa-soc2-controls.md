# HIPAA Security Rule & SOC 2 control mapping

How the platform implements technical safeguards, with pointers to the code that is the evidence. (Administrative safeguards such as risk assessments, training, and BAAs live outside this repo. AWS, Snowflake, and Temporal Cloud are all used under BAAs, and only HIPAA-eligible AWS services are used.)

| Requirement | HIPAA ref | SOC 2 | Implementation | Evidence |
|---|---|---|---|---|
| Unique user identification | 164.312(a)(2)(i) | CC6.1 | IAM Identity Center for humans; per-service IAM roles; IAM DB auth (no shared DB passwords) | `modules/aurora-postgres` (`iam_database_authentication_enabled`), `envs/prod` task policies |
| Separation of duties (DB) | 164.308(a)(3) | CC6.3 | Master credential readable only by a one-off `db-admin` task's execution role; runtime roles have no DDL/DELETE; audit log append-only for the app role | `modules/db-admin-task`, `intake_api/admin.py`, `test_admin.py` |
| Emergency access | 164.312(a)(2)(ii) | CC6.1 | Break-glass role (MFA, alerting on use) outside this repo; account root retains KMS admin to prevent lockout | `modules/kms` `AccountAdmin` statement |
| Automatic logoff / session limits | 164.312(a)(2)(iii) | CC6.1 | 1h max STS sessions for CI; 15-min IAM DB tokens | `bootstrap/github-oidc`, `db.py` |
| Encryption at rest | 164.312(a)(2)(iv) | CC6.1, C1.1 | CMKs per data classification, annual rotation; Aurora, DynamoDB, S3, logs, backups, AMP all CMK-encrypted; **field-level envelope encryption** for direct identifiers | `modules/kms`, `crypto.py`, ADR-0001 |
| Audit controls | 164.312(b) | CC7.2 | Append-only `phi_access_log` (DB trigger), pgaudit (DDL/role/write, no parameters), CloudTrail (org level), VPC flow logs | `migrations/0001_initial.py`, `aurora-postgres` parameter group, `network` flow logs |
| Integrity | 164.312(c)(1) | PI1.1 | AES-GCM authenticated encryption with row/column-bound AAD detects tampering; decrypt failures page security | `crypto.py`, `security-phi.yml` |
| Authentication | 164.312(d) | CC6.1 | OIDC federation for CI (no static keys), SSO for Grafana, mTLS to Temporal Cloud, key-pair auth to Snowflake | `bootstrap/github-oidc`, `observability` module, `worker.py` |
| Transmission security | 164.312(e)(1) | CC6.7 | TLS 1.2+ ALB policy, `rds.force_ssl`, S3 deny non-TLS, VPC endpoints keep AWS API traffic private | `ecs-fargate-service`, `aurora-postgres`, `envs/prod` bucket policy, `network` |
| Minimum necessary | 164.502(b) | C1.1 | Export worker reads only Safe Harbor columns, has no `kms:Decrypt`; Snowflake masking policies | `activities.py`, `snowflake-analytics` |
| De-identification | 164.514(b)(2) | C1.2 | Safe Harbor implementation with allow-listed output schema and tests | `deidentify.py`, `test_deidentify.py` |
| Activity review | 164.308(a)(1)(ii)(D) | CC7.3 | PHI access anomaly alert vs. weekly baseline | `security-phi.yml` |
| Contingency plan: backups | 164.308(a)(7)(ii)(A) | A1.2 | PITR 35d, daily AWS Backup with 6-year retention, cross-region copy, vault lock (WORM) | `aurora-postgres` |
| Contingency plan: DR & testing | 164.308(a)(7)(ii)(B),(D) | A1.3 | Weekly automated restore drill with measured RTO/RPO; alerts when failed or stale | `dr-restore-drill`, `data-platform.yml`, runbook |
| Change management | n/a | CC8.1 | PR review + CODEOWNERS, plan-as-comment, policy-as-code, signed images, approval-gated prod deploys | `.github/` |
| Vulnerability management | 164.308(a)(1) | CC7.1 | Trivy image scanning, gitleaks, Checkov, patched base images | `ci.yml` |
| Monitoring | n/a | CC7.2, A1.1 | SLOs with burn-rate alerting, tested alert rules | `observability/` |
| Data retention | 164.316(b)(2) | C1.2 | 6-year backup retention for documentation; log retention tiers | `envs/prod` (`long_term_retention_days = 2190`) |
