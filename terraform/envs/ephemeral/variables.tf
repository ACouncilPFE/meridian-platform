variable "pr_number" {
  type = number
}

variable "image" {
  type = string
}

variable "ttl_hours" {
  description = "Hard upper bound on lifetime; the reaper destroys anything past expires-at."
  type        = number
  default     = 72
}
