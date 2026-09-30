output "kms_key_arn" {
  value = aws_kms_key.platform.arn
}

output "kms_key_id" {
  value = aws_kms_key.platform.key_id
}

output "app_config_secret_arn" {
  value = aws_secretsmanager_secret.app_config.arn
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "cognito_domain" {
  value = aws_cognito_user_pool_domain.this.domain
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_agent_m2m_client_id" {
  value = aws_cognito_user_pool_client.agent_m2m.id
}

output "cognito_agent_m2m_client_secret" {
  value     = aws_cognito_user_pool_client.agent_m2m.client_secret
  sensitive = true
}

output "cognito_issuer_url" {
  description = "OIDC discovery issuer for this user pool — used as the CUSTOM_JWT authorizer discovery_url for the AgentCore Gateway."
  value       = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

data "aws_region" "current" {}
