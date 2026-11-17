output "intake_api_url" {
  value = "https://${module.intake_api.alb_dns_name}"
}

output "grafana_url" {
  value = "https://${module.observability.grafana_endpoint}"
}

output "aurora_writer_endpoint" {
  value = module.aurora.writer_endpoint
}

output "dr_drill_state_machine" {
  value = module.dr_drill.state_machine_arn
}
