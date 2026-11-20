output "amp_workspace_arn" {
  value = aws_prometheus_workspace.this.arn
}

output "amp_workspace_id" {
  value = aws_prometheus_workspace.this.id
}

output "amp_remote_write_endpoint" {
  value = aws_prometheus_workspace.this.prometheus_endpoint
}

output "grafana_endpoint" {
  value = one(aws_grafana_workspace.this[*].endpoint)
}

output "grafana_workspace_id" {
  value = one(aws_grafana_workspace.this[*].id)
}

output "alert_topic_arns" {
  value = { for k, v in aws_sns_topic.alerts : k => v.arn }
}
