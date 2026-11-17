variable "name" {
  type = string
}

variable "hash_key" {
  type = string
}

variable "range_key" {
  type    = string
  default = null
}

variable "attributes" {
  description = "Key attribute name => type (S | N | B). Only attributes used in keys/indexes."
  type        = map(string)
}

variable "global_secondary_indexes" {
  type = map(object({
    hash_key        = string
    range_key       = optional(string)
    projection_type = optional(string, "ALL")
  }))
  default = {}
}

variable "ttl_attribute" {
  type    = string
  default = null
}

variable "kms_key_arn" {
  type = string
}

variable "replica_regions" {
  type = list(object({
    region      = string
    kms_key_arn = string
  }))
  default = []
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "data_classification" {
  type    = string
  default = "confidential"
}

variable "tags" {
  type    = map(string)
  default = {}
}
