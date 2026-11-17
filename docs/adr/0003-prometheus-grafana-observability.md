# ADR-0003: Prometheus + Grafana (managed) for observability

**Status:** Accepted

## Context
We need metrics, alerting, and tracing standards across services, Temporal workers, and data infrastructure, inside a HIPAA boundary, without a per-host pricing model that discourages instrumentation.

## Decision
- **Metrics:** the Prometheus data model and PromQL everywhere. In AWS, Amazon Managed Service for Prometheus (HIPAA-eligible, CMK-encrypted). Locally, plain Prometheus.
- **Collection:** an AWS Distro for OpenTelemetry sidecar on every Fargate task (part of the paved-road module) scrapes `/metrics` and remote-writes with SigV4. Lambdas use the ADOT layer.
- **Tracing:** OpenTelemetry SDK → collector → Grafana Tempo, with exemplars linking metrics to traces.
- **Dashboards:** Amazon Managed Grafana (SSO). Dashboards are generated from Python so every service gets the same golden-signals and SLO layout, and CI fails on drift.
- **Alerting:** rules live in the repo, are deployed to AMP rule groups by Terraform, and are **unit-tested with promtool**. SLO alerts use multi-window burn rates instead of static thresholds.

## Consequences
- One rule source, two runtimes: the same YAML runs in docker-compose and AMP, so alerts are developed and tested locally.
- PHI controls apply to telemetry too. Labels are low-cardinality and identifier-free, and the collector deletes or hashes PHI-prone span attributes before export (defense in depth).
- CloudWatch-only metrics (RDS replica lag) are pulled into Prometheus via YACE.
- We own more of the stack than with a SaaS APM. The managed AMP and AMG services keep that to configuration rather than operating clusters.
