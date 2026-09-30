variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "gold_bucket_arn" {
  type = string
}

variable "gold_bucket_name" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "embedding_model_id" {
  description = "Bedrock embedding model used to index knowledge base documents."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "vector_store_type" {
  description = <<-EOT
    "OPENSEARCH_SERVERLESS" (implemented below, ~$350/mo floor even
    idle — https://aws.amazon.com/opensearch-service/pricing/) or
    "S3_VECTORS" (AWS's cost-optimized default since Dec 2025, no idle
    floor, ~90% cheaper for most RAG-sized corpora). This module ships
    the OpenSearch Serverless path since its Terraform schema is the
    most battle-tested one; S3 Vectors support in aws_bedrockagent_knowledge_base
    landed more recently, so double-check the current
    storage_configuration block in the hashicorp/aws provider docs
    before switching — and prefer it for anything but a large,
    high-QPS production index.
  EOT
  type    = string
  default = "OPENSEARCH_SERVERLESS"

  validation {
    condition     = contains(["OPENSEARCH_SERVERLESS", "S3_VECTORS"], var.vector_store_type)
    error_message = "vector_store_type must be OPENSEARCH_SERVERLESS or S3_VECTORS."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
