variable "repo_name" {
  description = "Name of the git repository this state bucket belongs to. Used in the bucket name, so it must be S3-name-safe (lowercase letters, digits, hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.repo_name))
    error_message = "repo_name must be 3-42 chars of lowercase letters, digits, and hyphens, starting and ending with a letter or digit."
  }
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Override for the bucket name. Leave empty to use '<repo_name>-tfstate-<account_id>', which is globally unique and self-describing."
  type        = string
  default     = ""
}

variable "access_log_bucket" {
  description = "Name of an existing S3 access-log bucket. When set, every read and write of state is logged there. The log bucket is an org-level resource shared across repos — create it once, outside this template. Empty disables logging."
  type        = string
  default     = ""
}

variable "access_log_prefix" {
  description = "Prefix for access-log objects in the log bucket. Defaults to '<state bucket name>/'."
  type        = string
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent state versions before expiring them. Versioning is what lets you recover a clobbered state file, but old versions accumulate cost forever without this."
  type        = number
  default     = 90
}
