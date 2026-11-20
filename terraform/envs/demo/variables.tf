variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image" {
  description = "intake-api image by digest (set by scripts/demo/up.sh)."
  type        = string
}

variable "allowed_cidr" {
  description = "Only this CIDR can reach the demo ALB (your public IP /32; up.sh detects it)."
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be a specific CIDR (e.g. 203.0.113.7/32), not the whole internet."
  }
}

variable "enable_managed_grafana" {
  description = "Requires IAM Identity Center in an AWS Organization. Default: run Grafana locally against AMP."
  type        = bool
  default     = false
}

variable "budget_alert_email" {
  description = "Email for AWS Budgets alerts on demo spend. Null = no budget."
  type        = string
  default     = null
}

variable "budget_limit_usd" {
  type    = number
  default = 25
}
