variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "silver_bucket_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "enable_studio_domain" {
  description = "Whether to stand up a SageMaker Studio domain for interactive notebook work. Off by default in dev to avoid idle-app costs — flip on when you actually need to explore data interactively; training/pipeline runs don't need it."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
