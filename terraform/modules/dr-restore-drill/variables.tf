variable "source_cluster_id" {
  type = string
}

variable "database_name" {
  type = string
}

variable "db_subnet_group_name" {
  type = string
}

variable "drill_security_group_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "lambda_subnet_ids" {
  description = "Private app-tier subnets (with NAT egress) for the verify Lambda."
  type        = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "lambda_source_dir" {
  type = string
}

variable "expected_tables" {
  type    = list(string)
  default = ["patients", "encounters", "alembic_version"]
}

variable "drill_instance_class" {
  type    = string
  default = "db.serverless"
}

variable "amp_workspace_arn" {
  type = string
}

variable "amp_remote_write_endpoint" {
  type = string
}

variable "schedule_expression" {
  type    = string
  default = "cron(0 3 ? * SUN *)"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "adot_python_layer_arn" {
  description = "ADOT Python Lambda layer ARN. Null = the module's pinned default for the current region (check aws-otel.github.io for newer versions)."
  type        = string
  default     = null
}

variable "expected_alembic_head" {
  description = "Alembic revision the restored DB must be at (set by CD from the deployed release)."
  type        = string
  default     = "0002"
}

variable "logs_kms_key_arn" {
  description = "Ops/logging CMK for the state machine log group (its key policy admits CloudWatch Logs)."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 365
}
