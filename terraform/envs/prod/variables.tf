variable "region" {
  type    = string
  default = "us-east-1"
}

variable "dr_region" {
  type    = string
  default = "us-west-2"
}

variable "certificate_arn" {
  type = string
}

variable "intake_api_image" {
  description = "Set by CD to an immutable digest."
  type        = string
}

variable "pipeline_worker_image" {
  type = string
}

variable "temporal_address" {
  description = "Temporal Cloud namespace endpoint, e.g. meridian-prod.abcde.tmprl.cloud:7233"
  type        = string
}

variable "temporal_mtls_secret_arn" {
  type = string
}

variable "tempo_otlp_endpoint" {
  description = "Grafana Tempo OTLP gRPC endpoint for traces."
  type        = string
}

variable "pagerduty_endpoint" {
  type      = string
  default   = null
  sensitive = true
}

variable "grafana_admin_group_ids" {
  type    = list(string)
  default = []
}

variable "nat_egress_cidrs" {
  type = list(string)
}

variable "snowflake_organization" {
  type = string
}

variable "snowflake_account" {
  type = string
}

variable "snowflake_s3_role_arn" {
  type = string
}
