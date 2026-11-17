# -----------------------------------------------------------------------------
# observability: Prometheus + Grafana, managed.
#  - Amazon Managed Service for Prometheus (AMP) workspace (HIPAA eligible)
#  - Recording + alerting rules loaded from /observability/prometheus/rules
#    (the SAME files the local docker-compose Prometheus uses: one source of truth)
#  - AMP Alertmanager routing -> SNS -> PagerDuty / Slack
#  - Amazon Managed Grafana workspace with IAM Identity Center (SSO) auth,
#    AMP + CloudWatch + X-Ray data sources
# -----------------------------------------------------------------------------

locals {
  tags = merge(var.tags, { "platform:module" = "observability" })
}

resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/prometheus/${var.name}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

resource "aws_prometheus_workspace" "this" {
  alias       = var.name
  kms_key_arn = var.kms_key_arn

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }

  tags = local.tags
}

resource "aws_prometheus_rule_group_namespace" "this" {
  for_each     = fileset(var.rules_dir, "*.yml")
  name         = trimsuffix(each.value, ".yml")
  workspace_id = aws_prometheus_workspace.this.id
  data         = file("${var.rules_dir}/${each.value}")
}

# --- Alerting ----------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  for_each          = toset(["critical", "warning"])
  name              = "${var.name}-alerts-${each.key}"
  kms_master_key_id = var.kms_key_arn
  tags              = local.tags
}

data "aws_iam_policy_document" "sns_from_amp" {
  for_each = aws_sns_topic.alerts
  statement {
    actions   = ["sns:Publish", "sns:GetTopicAttributes"]
    resources = [each.value.arn]
    principals {
      type        = "Service"
      identifiers = ["aps.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_prometheus_workspace.this.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  for_each = aws_sns_topic.alerts
  arn      = each.value.arn
  policy   = data.aws_iam_policy_document.sns_from_amp[each.key].json
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count                  = var.pagerduty_endpoint == null ? 0 : 1
  topic_arn              = aws_sns_topic.alerts["critical"].arn
  protocol               = "https"
  endpoint               = var.pagerduty_endpoint
  endpoint_auto_confirms = true
}

data "aws_region" "current" {}

resource "aws_prometheus_alert_manager_definition" "this" {
  workspace_id = aws_prometheus_workspace.this.id
  definition   = <<-EOT
    alertmanager_config: |
      route:
        receiver: warning
        group_by: [alertname, service, env]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
        routes:
          - matchers: [ 'severity="critical"' ]
            receiver: critical
            repeat_interval: 1h
      inhibit_rules:
        - source_matchers: [ 'severity="critical"' ]
          target_matchers: [ 'severity="warning"' ]
          equal: [alertname, service]
      receivers:
        - name: critical
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts["critical"].arn}
              sigv4:
                region: ${data.aws_region.current.name}
              attributes:
                severity: critical
        - name: warning
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts["warning"].arn}
              sigv4:
                region: ${data.aws_region.current.name}
              attributes:
                severity: warning
  EOT
}

# --- Grafana -----------------------------------------------------------------
data "aws_iam_policy_document" "grafana_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  name_prefix        = "${var.name}-grafana-"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonGrafanaCloudWatchAccess",
    "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess",
    "arn:aws:iam::aws:policy/AWSXrayReadOnlyAccess",
  ]
  tags = local.tags
}

resource "aws_grafana_workspace" "this" {
  name                     = var.name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
  grafana_version          = "10.4"

  vpc_configuration {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.grafana.id]
  }

  tags = local.tags
}

resource "aws_security_group" "grafana" {
  name_prefix = "${var.name}-grafana-"
  vpc_id      = var.vpc_id
  description = "Managed Grafana ENIs (reach Tempo / private data sources)"

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 3200
    to_port     = 3200
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = local.tags
}

resource "aws_grafana_role_association" "admins" {
  count        = length(var.grafana_admin_group_ids) > 0 ? 1 : 0
  role         = "ADMIN"
  group_ids    = var.grafana_admin_group_ids
  workspace_id = aws_grafana_workspace.this.id
}

resource "aws_grafana_role_association" "viewers" {
  count        = length(var.grafana_viewer_group_ids) > 0 ? 1 : 0
  role         = "VIEWER"
  group_ids    = var.grafana_viewer_group_ids
  workspace_id = aws_grafana_workspace.this.id
}
