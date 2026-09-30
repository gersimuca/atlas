variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "repository_names" {
  description = "Service names to create one ECR repository each for."
  type        = list(string)
  default     = ["api-gateway-service", "agent-orchestrator", "ingestion-worker"]
}

variable "kms_key_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
