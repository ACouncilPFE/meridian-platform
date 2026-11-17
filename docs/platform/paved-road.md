# The paved road: shipping a new service

Goal: a product team goes from "new repo" to "production service with HA, TLS, autoscaling, least-privilege IAM, metrics, traces, alerts, and dashboards" **without filing a platform ticket**.

## 1. Add the service (about 15 lines)

```hcl
module "scheduling_api" {
  source = "../../modules/ecs-fargate-service"

  name        = "scheduling-api"
  image       = var.scheduling_api_image   # set by CD to an immutable digest
  environment = "prod"
  # shared inputs (cluster, VPC, AMP, KMS) come from local.service_defaults

  environment_variables = { DB_HOST = module.aurora.writer_endpoint }
  task_policy_json      = data.aws_iam_policy_document.scheduling_api.json
}
```

## 2. What you get by default

| Concern | Default |
|---|---|
| Availability | ≥2 tasks across AZs, ALB health checks, deploy circuit breaker with auto-rollback |
| Security | Private subnets, TLS 1.2+/1.3 ALB, non-root, read-only root FS, no ECS Exec, secrets from Secrets Manager |
| IAM | Task role can remote-write its own metrics, nothing else. You add exactly what you need. |
| Observability | OTel sidecar scrapes `/metrics` → Managed Prometheus, OTLP traces → Tempo, PHI attributes scrubbed |
| Logs | KMS-encrypted CloudWatch log group, 1-year retention |
| Scaling | CPU target tracking, 2 to 10 tasks |

## 3. Instrument your app

Expose `http_requests_total{method,route,status}` and `http_request_duration_seconds` on `/metrics`. The intake-api [`observability.py`](../../services/intake-api/src/intake_api/observability.py) is the reference implementation, so copy it.

## 4. Get SLOs, alerts, and a dashboard

1. Copy `observability/prometheus/rules/slo-intake-api.yml`, replace the service name, and add a promtool test.
2. Add `service_golden_signals("scheduling-api")` to `DASHBOARDS` in `build_dashboards.py` and run `make dashboards`.

## 5. Preview it

Open a PR and add the `preview` label. You get a URL to a full stack with synthetic data, torn down when the PR closes.

## Escape hatches

If the paved road doesn't fit, talk to platform. If the need is general, the answer is usually a new module input rather than a fork. Forking a module means you own it.
