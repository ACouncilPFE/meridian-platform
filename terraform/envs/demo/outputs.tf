output "region" {
  value = var.region
}

output "api_url" {
  value = module.intake_api.url
}

output "ecr_repository_url" {
  value = aws_ecr_repository.intake_api.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service" {
  value = module.intake_api.service_name
}

output "service_security_group_id" {
  value = module.intake_api.security_group_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "db_admin_task_definition" {
  value = module.db_admin.task_definition_arn
}

output "amp_workspace_id" {
  value = module.observability.amp_workspace_id
}

output "amp_query_url" {
  description = "Prometheus-compatible query endpoint (SigV4) for Grafana."
  value       = module.observability.amp_remote_write_endpoint
}

output "dr_drill_state_machine_arn" {
  value = module.dr_drill.state_machine_arn
}

output "aurora_cluster_id" {
  value = module.aurora.cluster_id
}
