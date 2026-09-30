output "memory_id" {
  value = aws_bedrockagentcore_memory.sessions.id
}

output "gateway_id" {
  value = aws_bedrockagentcore_gateway.tools.id
}

output "gateway_url" {
  value = aws_bedrockagentcore_gateway.tools.gateway_url
}

output "query_lakehouse_lambda_name" {
  value = aws_lambda_function.query_lakehouse.function_name
}

output "get_document_metadata_lambda_name" {
  value = aws_lambda_function.get_document_metadata.function_name
}
