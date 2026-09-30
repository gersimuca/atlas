variable "project_name" {
  type    = string
  default = "atlas"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (cheaper, dev default). false = one NAT per AZ (HA, prod default)."
  type        = bool
  default     = false
}

variable "eks_cluster_version" {
  type    = string
  default = "1.34"
}

variable "eks_compute_type" {
  description = "\"fargate\" for dev (no idle node cost) or \"managed_node_group\" for prod (Karpenter-managed)."
  type        = string
  default     = "managed_node_group"
}

variable "bedrock_model_id" {
  description = <<-EOT
    Cross-region inference profile ID for the Claude model the agent
    calls via Converse. Bedrock's model catalog and IDs change often —
    check Bedrock console > Model access for what's enabled in your
    account/region before deploying, and update this value. As of
    writing, Claude Sonnet 4.6/Sonnet 5/Opus 4.8 are all available on
    Bedrock; this defaults to the widely-available 4.6 cross-region
    profile.
  EOT
  type    = string
  default = "us.anthropic.claude-sonnet-4-6"
}

variable "bedrock_embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "vector_store_type" {
  type    = string
  default = "OPENSEARCH_SERVERLESS"
}

variable "enable_sagemaker_studio" {
  type    = bool
  default = false
}
