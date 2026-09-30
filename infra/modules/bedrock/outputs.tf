output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.this.id
}

output "knowledge_base_arn" {
  value = aws_bedrockagent_knowledge_base.this.arn
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.gold_documents.data_source_id
}

output "guardrail_id" {
  value = aws_bedrock_guardrail.this.guardrail_id
}

output "guardrail_version" {
  value = aws_bedrock_guardrail_version.published.version
}

output "opensearch_collection_endpoint" {
  value = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "knowledge_base_role_arn" {
  value = aws_iam_role.knowledge_base.arn
}
