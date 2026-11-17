# Meridian Platform

**A HIPAA-ready, self-service AWS platform for a healthcare product team, built as code.**

Meridian is a reference platform for a (fictional) digital health company. It shows how I'd design, build, and operate the infrastructure a regulated product team runs on: paved-road Terraform modules, a highly available Postgres data tier with *proven* disaster recovery, a de-identified analytics pipeline into Snowflake orchestrated by Temporal, Prometheus + Grafana observability with SLOs and tested alerts, and keyless GitHub Actions CI/CD with per-PR preview environments.

Everything here is real, runnable code. The Python services and DR Lambda have test suites, and the Prometheus alert rules have `promtool` unit tests.

---

## Architecture

```mermaid
flowchart LR
  subgraph GH[GitHub]
    PR[Pull request] -->|OIDC, no keys| CI[Actions: test, scan, plan]
    CI -->|label: preview| EPH[Ephemeral env pr-N]
    MAIN[main] -->|approval: production env| CD[Build, sign, migrate, apply]
  end

  subgraph AWS[AWS us-east-1 - VPC, 3 AZs]
    direction LR
    ALB[ALB TLS1.2+] --> API[intake-api<br/>Fargate + OTel sidecar]
    API -->|IAM auth, TLS| AUR[(Aurora Postgres<br/>writer + 2 readers)]
    API --> DDB[(DynamoDB<br/>PITR, global table)]
    API -.->|envelope encryption| KMS{{KMS: PHI key}}
    WRK[pipeline-worker<br/>Temporal activities] -->|read replica,<br/>Safe Harbor columns only| AUR
    WRK -->|de-identified JSON| S3[(S3 export, KMS)]
    SFN[Step Functions<br/>weekly restore drill] --> AUR
    SFN --> LAM[Lambda: verify<br/>RTO/RPO]
  end

  TC[Temporal Cloud<br/>mTLS] <--> WRK
  S3 -->|storage integration| SF[(Snowflake<br/>masking policies)]
  AUR -->|AWS Backup copy| DR[(us-west-2<br/>vault-locked backups)]

  subgraph OBS[Observability]
    AMP[Managed Prometheus] --> AM[Alertmanager] --> PD[PagerDuty / Slack]
    AMP --> GRAF[Managed Grafana]
    TEMPO[Tempo traces] --> GRAF
  end
  API -.metrics/traces.-> AMP
  WRK -.metrics.-> AMP
  LAM -.dr metrics.-> AMP
```

## How this maps to the role

| Responsibility | Where to look |
|---|---|
| **Secure, scalable IaC with reusable modules and paved roads** | [`terraform/modules/`](terraform/modules): `network`, `kms`, `aurora-postgres`, `dynamodb-table`, `ecs-fargate-service`, `observability`, `dr-restore-drill`, `snowflake-analytics`. A product team gets a production-grade service from about 15 lines ([paved-road guide](docs/platform/paved-road.md)). |
| **Postgres / Aurora / Snowflake: HA, backups, DR, migrations** | Multi-AZ Aurora with IAM auth, pgaudit, PITR, and vault-locked cross-region AWS Backup ([module](terraform/modules/aurora-postgres/main.tf)). An automated **weekly restore drill** measures real RTO/RPO ([state machine](terraform/modules/dr-restore-drill/state-machine.asl.json)). Expand/contract Alembic migrations are tested up, down, and for ORM drift ([tests](services/intake-api/tests/test_migrations.py)). Snowflake has RBAC, masking policies, and a network policy ([module](terraform/modules/snowflake-analytics/main.tf)). |
| **Self-service developer platform: CI/CD, testing, local + ephemeral envs** | [`ci.yml`](.github/workflows/ci.yml) (tests, Terraform validate, tflint, Checkov, Trivy, gitleaks, plan-as-PR-comment). [`ephemeral-env.yml`](.github/workflows/ephemeral-env.yml) gives each PR a full stack with synthetic data, cleaned up by a TTL reaper. [`deploy.yml`](.github/workflows/deploy.yml) builds once, signs with cosign, runs migrations, applies Terraform, and passes an SLO gate. `make up` starts the whole stack locally. |
| **Observability standards** (Prometheus + Grafana) | Multi-window burn-rate SLO alerts, PHI security alerts, and DR alerts ([rules](observability/prometheus/rules)) with **promtool unit tests** ([tests](observability/prometheus/tests/alerts.test.yml)). Dashboards are generated from code ([generator](observability/grafana/build_dashboards.py)). The OTel sidecar on every service scrubs PHI from traces. The same rule files run locally and in Amazon Managed Prometheus. |
| **Engineering standards, review, mentorship** | [ADRs](docs/adr), [runbooks](docs/runbooks), [PR template](.github/pull_request_template.md) with a risk checklist, [CODEOWNERS](.github/CODEOWNERS), policy-as-code with justified exceptions ([`.checkov.yml`](.checkov.yml)). |
| **HIPAA / SOC 2: IAM, network security, PHI handling** | [Control mapping](docs/compliance/hipaa-soc2-controls.md). Field-level envelope encryption bound to row and column ([crypto.py](services/intake-api/src/intake_api/crypto.py)). Append-only audit log enforced by a DB trigger. Log redaction. Safe Harbor de-identification with an allow-listed schema ([deidentify.py](workflows/pipeline-worker/src/pipeline_worker/deidentify.py)). Isolated data subnets, VPC endpoints, and keyless OIDC CI ([bootstrap](terraform/bootstrap/github-oidc/main.tf)). |
| **AI-native development with validation and oversight** | [`CLAUDE.md`](CLAUDE.md) sets out what the agent may and may not do, which checks must pass, and which changes always need human review. [ADR-0005](docs/adr/0005-ai-assisted-development.md) covers it in more depth. |
| **Temporal workflow orchestration** | [`DeidentifyExportWorkflow`](workflows/pipeline-worker/src/pipeline_worker/workflow.py) is resumable, uses per-step retry policies, and calls `continue_as_new` for unbounded backfills. Raw PHI never enters workflow history. |
| **AWS Fargate, Lambda, Step Functions, DynamoDB** | All used where they fit: Fargate for services and workers, Step Functions plus Lambda for the DR drill, DynamoDB global table for idempotency keys. |

## Repository layout

```
terraform/
  modules/            reusable, opinionated building blocks (the paved road)
  envs/prod/          production composition (primary + DR region)
  envs/ephemeral/     per-PR preview stacks (workspace per PR)
  bootstrap/          GitHub OIDC roles (keyless CI/CD)
services/intake-api/  FastAPI service: PHI intake, envelope encryption, audit log, Alembic migrations
workflows/pipeline-worker/  Temporal worker: Aurora -> Safe Harbor -> S3 -> Snowflake
lambdas/dr_verify/    restore-drill verification + RTO/RPO metrics
observability/        Prometheus rules + tests, Grafana dashboards-as-code, local stack configs
docs/                 ADRs, runbooks, compliance mapping, paved-road guide
.github/workflows/    CI, ephemeral envs, deploy, on-demand DR drill
```

## Quick start

```bash
make up          # Postgres, API, Temporal, Prometheus, Grafana, Tempo, Alertmanager
make seed        # 200 synthetic patients
open http://localhost:3000   # Grafana: "intake-api: SLO & golden signals"

make test        # every test suite + promtool rule tests + dashboard drift check
make tf-check    # terraform fmt + validate across all modules/envs
```

## Design decisions

- [ADR-0001](docs/adr/0001-field-level-encryption.md): Field-level envelope encryption on top of storage encryption
- [ADR-0002](docs/adr/0002-temporal-for-data-pipelines.md): Temporal for data pipelines instead of cron or Airflow
- [ADR-0003](docs/adr/0003-prometheus-grafana-observability.md): Prometheus + Grafana (managed) for observability
- [ADR-0004](docs/adr/0004-ephemeral-environments.md): Per-PR ephemeral environments with synthetic data
- [ADR-0005](docs/adr/0005-ai-assisted-development.md): AI-assisted development with explicit oversight boundaries

## Scope notes

This is a portfolio project, not a deployed production system. `envs/dev` isn't included: it has the same composition as `prod` with dev-sized inputs, plus outputs that the ephemeral stacks read through remote state. Account IDs, ARNs, and `OWNER` placeholders need replacing before anything is applied. The Temporal workflow test uses Temporal's time-skipping test server, which CI downloads automatically.
