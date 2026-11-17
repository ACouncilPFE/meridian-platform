variable "name" {
  description = "Name prefix for all resources."
  type        = string
}

variable "region" {
  description = "AWS region (used to build VPC endpoint service names)."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Must be a /16 so the module can carve 12 /20 subnets."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && endswith(var.cidr_block, "/16")
    error_message = "cidr_block must be a valid /16."
  }
}

variable "az_count" {
  description = "Number of AZs to span (2-4). Use >= 2 anywhere PHI lives so the data tier is multi-AZ."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "Cost saver for ephemeral/dev envs. Never true in prod (AZ failure would cut egress)."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Interface VPC endpoints to create."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs", "kms", "secretsmanager", "sts", "states", "ssm"]
}

variable "kms_key_arn" {
  description = "CMK used to encrypt flow logs."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Flow log retention. HIPAA documentation retention is 6 years; logs usually ship to an archive bucket for long-term retention."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
