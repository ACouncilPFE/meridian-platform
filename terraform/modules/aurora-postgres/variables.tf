variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Isolated data-tier subnets (no internet route)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Aurora requires subnets in at least 2 AZs."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "instance_class" {
  description = "Use db.serverless for Aurora Serverless v2."
  type        = string
  default     = "db.serverless"
}

variable "instance_count" {
  description = "1 writer + N-1 readers. >= 2 for HA (automatic failover to a reader in another AZ)."
  type        = number
  default     = 2
}

variable "serverless_min_acu" {
  type    = number
  default = 0.5
}

variable "serverless_max_acu" {
  type    = number
  default = 16
}

variable "kms_key_arn" {
  type = string
}

variable "backup_retention_days" {
  description = "PITR window (1-35)."
  type        = number
  default     = 14
}

variable "long_term_retention_days" {
  description = "AWS Backup retention for daily snapshots."
  type        = number
  default     = 365
}

variable "dr_backup_vault_arn" {
  description = "Backup vault in the DR region. Null disables cross-region copy."
  type        = string
  default     = null
}

variable "enable_vault_lock" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "slow_query_ms" {
  type    = number
  default = 500
}

variable "data_classification" {
  type    = string
  default = "phi"
}

variable "tags" {
  type    = map(string)
  default = {}
}
