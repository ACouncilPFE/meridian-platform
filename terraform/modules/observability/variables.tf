variable "name" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "rules_dir" {
  description = "Directory containing Prometheus rule files (*.yml)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "pagerduty_endpoint" {
  description = "PagerDuty Events API (SNS integration) URL for critical alerts."
  type        = string
  default     = null
  sensitive   = true
}

variable "grafana_admin_group_ids" {
  description = "IAM Identity Center group IDs granted Grafana Admin."
  type        = list(string)
  default     = []
}

variable "grafana_viewer_group_ids" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_managed_grafana" {
  type    = bool
  default = true
}
