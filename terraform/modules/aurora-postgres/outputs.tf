output "cluster_arn" {
  value = aws_rds_cluster.this.arn
}

output "cluster_id" {
  value = aws_rds_cluster.this.id
}

output "cluster_resource_id" {
  description = "Used to scope rds-db:connect IAM policies."
  value       = aws_rds_cluster.this.cluster_resource_id
}

output "writer_endpoint" {
  value = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  value = aws_rds_cluster.this.reader_endpoint
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "master_user_secret_arn" {
  value = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "backup_vault_name" {
  value = aws_backup_vault.primary.name
}
