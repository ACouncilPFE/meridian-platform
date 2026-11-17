variable "name" {
  type = string
}

variable "keys" {
  description = "Map of key name => config."
  type = map(object({
    description         = string
    classification      = string # phi | confidential | internal
    multi_region        = optional(bool, false)
    user_principal_arns = optional(list(string), [])
    service_principals  = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for k in values(var.keys) : contains(["phi", "confidential", "internal"], k.classification)])
    error_message = "classification must be one of phi, confidential, internal."
  }
}

variable "deletion_window_in_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
