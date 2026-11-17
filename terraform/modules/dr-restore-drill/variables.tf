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

variable "data_subnet_ids" {
  type = list(string)
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
  description = "AWS Distro for OpenTelemetry Python Lambda layer ARN for the region."
  type        = string
  default     = "arn:aws:lambda:us-east-1:901920570463:layer:aws-otel-python-arm64-ver-1-25-0:1"
}

variable "expected_alembic_head" {
  description = "Alembic revision the restored DB must be at (set by CD from the deployed release)."
  type        = string
  default     = "0002"
}
