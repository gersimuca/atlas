variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "cognito_issuer_url" {
  description = "Cognito user pool OIDC discovery issuer, used as the Gateway's CUSTOM_JWT authorizer."
  type        = string
}

variable "cognito_agent_m2m_client_id" {
  description = "Cognito app client ID allowed to call the Gateway (the agent-orchestrator's machine-to-machine client)."
  type        = string
}

variable "athena_workgroup_name" {
  type = string
}

variable "glue_gold_database" {
  type = string
}

variable "gold_bucket_arn" {
  type = string
}

variable "athena_results_bucket_arn" {
  type = string
}

variable "document_metadata_table_name" {
  type = string
}

variable "document_metadata_table_arn" {
  type = string
}

variable "memory_event_expiry_days" {
  description = "How long AgentCore Memory retains a conversation session before it expires (7-365)."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
