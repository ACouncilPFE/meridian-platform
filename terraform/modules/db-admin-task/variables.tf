variable "name" {
  description = "Service the database belongs to (e.g. intake-api)."
  type        = string
}

variable "environment" {
  type = string
}

variable "image" {
  description = "Same image digest as the release being deployed."
  type        = string
}

variable "db_host" {
  type = string
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "db_admin_user" {
  type    = string
  default = "platform_admin"
}

variable "app_db_user" {
  type    = string
  default = "intake_api"
}

variable "verifier_db_user" {
  type    = string
  default = "dr_verifier"
}

variable "master_secret_arn" {
  description = "RDS-managed master user secret (aurora-postgres module output)."
  type        = string
}

variable "master_secret_kms_key_arn" {
  type = string
}

variable "logs_kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "tags" {
  type    = map(string)
  default = {}
}
