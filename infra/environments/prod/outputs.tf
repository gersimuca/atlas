########################################
# Cluster
########################################

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.aws_region
}

########################################
# Container registry
########################################

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

########################################
# Lakehouse
########################################

output "bronze_bucket_name" {
  value = module.lakehouse.bronze_bucket_name
}

output "gold_bucket_name" {
  value = module.lakehouse.gold_bucket_name
}

output "glue_gold_database" {
  value = module.lakehouse.glue_gold_database
}

output "athena_workgroup_name" {
  value = module.lakehouse.athena_workgroup_name
}

########################################
# AI / ML
########################################

output "bedrock_knowledge_base_id" {
  value = module.bedrock.knowledge_base_id
}

output "bedrock_guardrail_id" {
  value = module.bedrock.guardrail_id
}

output "bedrock_guardrail_version" {
  value = module.bedrock.guardrail_version
}

output "agentcore_gateway_url" {
  value = module.agentcore.gateway_url
}

output "agentcore_memory_id" {
  value = module.agentcore.memory_id
}

output "sagemaker_model_package_group" {
  value = module.sagemaker.model_package_group_name
}

output "sagemaker_execution_role_arn" {
  value = module.sagemaker.execution_role_arn
}

########################################
# Ingestion
########################################

output "document_metadata_table_name" {
  value = aws_dynamodb_table.document_metadata.name
}

output "ingestion_queue_url" {
  value = aws_sqs_queue.ingestion_events.id
}

########################################
# Identity — feeds Helm values (ConfigMap) and CI/CD
########################################

output "cognito_user_pool_id" {
  value = module.security.cognito_user_pool_id
}

output "cognito_web_client_id" {
  value = module.security.cognito_web_client_id
}

output "cognito_domain" {
  value = module.security.cognito_domain
}

########################################
# IRSA role ARNs — plugged into the Helm chart's serviceAccount.annotations
########################################

output "irsa_role_arns" {
  value = {
    api_gateway_service = aws_iam_role.api_gateway_service.arn
    agent_orchestrator   = aws_iam_role.agent_orchestrator.arn
    ingestion_worker     = aws_iam_role.ingestion_worker.arn
  }
}
