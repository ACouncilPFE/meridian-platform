variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase kebab-case, <= 31 chars."
  }
}

variable "environment" {
  type = string
}

variable "image" {
  description = "Immutable image reference (digest preferred: repo@sha256:...)."
  type        = string
}

variable "cluster_arn" {
  type = string
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

variable "public_subnet_ids" {
  type    = list(string)
  default = []
}

variable "alb_deletion_protection" {
  description = "Keep on everywhere except throwaway envs (demo, PR previews)."
  type        = bool
  default     = true
}

variable "internal" {
  description = "Internal ALB (default). Public only for edge-facing APIs."
  type        = bool
  default     = true
}

variable "alb_ingress_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/8"]
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener. Null = plain HTTP (only allowed outside prod, for demos)."
  type        = string
  default     = null
}

variable "alb_access_logs_bucket" {
  type    = string
  default = null
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}

variable "metrics_path" {
  type    = string
  default = "/metrics"
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 10
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "ENV_VAR => Secrets Manager / SSM ARN."
  type        = map(string)
  default     = {}
}

variable "secrets_kms_key_arns" {
  type    = list(string)
  default = []
}

variable "task_policy_json" {
  description = "Additional least-privilege policy for the task role."
  type        = string
  default     = null
}

variable "additional_security_group_ids" {
  type    = list(string)
  default = []
}

variable "amp_workspace_arn" {
  type = string
}

variable "amp_remote_write_endpoint" {
  description = "AMP workspace prometheus_endpoint (ends with /)."
  type        = string
}

variable "traces_otlp_endpoint" {
  description = "OTLP gRPC endpoint of the shared trace backend (Grafana Tempo). Empty = AWS X-Ray."
  type        = string
  default     = ""
}

variable "adot_image" {
  type    = string
  default = "public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0"
}

variable "logs_kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "data_classification" {
  type    = string
  default = "phi"
}

variable "tags" {
  type    = map(string)
  default = {}
}
