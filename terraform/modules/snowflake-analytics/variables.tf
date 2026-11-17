variable "name" {
  type = string
}

variable "analyst_warehouse_size" {
  type    = string
  default = "SMALL"
}

variable "allowed_ip_cidrs" {
  description = "NAT gateway EIPs (/32) allowed to authenticate as service users."
  type        = list(string)
}

variable "snowflake_s3_role_arn" {
  type = string
}

variable "export_bucket" {
  type = string
}
