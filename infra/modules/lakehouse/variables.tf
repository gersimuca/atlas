variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "glue_job_role_arn" {
  description = "IAM role ARN Glue jobs and crawlers assume. Defined at the environment level since it needs to reference this module's bucket ARNs (avoids a circular module dependency)."
  type        = string
}

variable "raw_zone_retention_days" {
  description = "Days before raw/bronze objects transition to Glacier for cheap long-term retention."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
