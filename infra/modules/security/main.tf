data "aws_caller_identity" "current" {}

########################################
# KMS — one CMK for the whole platform (S3, Secrets Manager, CloudWatch,
# AgentCore Memory). A single key keeps IAM simpler for a project this
# size; split per-data-class keys once you have compliance boundaries
# that require it.
########################################

resource "aws_kms_key" "platform" {
  description             = "${var.project_name}-${var.environment} platform CMK"
  deletion_window_in_days = var.environment == "prod" ? 30 : 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountRootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowLoggingServices"
        Effect = "Allow"
        Principal = {
          Service = [
            "logs.amazonaws.com",
            "s3.amazonaws.com",
            "secretsmanager.amazonaws.com",
            "bedrock-agentcore.amazonaws.com",
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-${var.environment}-platform-key" })
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${var.project_name}-${var.environment}-platform"
  target_key_id = aws_kms_key.platform.key_id
}

########################################
# Secrets Manager — app configuration. Values are placeholders; rotate
# and populate for real via `aws secretsmanager put-secret-value` or the
# console, never through a committed tfvars file.
########################################

resource "aws_secretsmanager_secret" "app_config" {
  name       = "${var.project_name}/${var.environment}/app-config"
  kms_key_id = aws_kms_key.platform.arn
  tags       = var.tags
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id     = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode(var.app_secret_config)

  lifecycle {
    ignore_changes = [secret_string] # real values are rotated out-of-band after first apply
  }
}

########################################
# Cognito — identity for both humans (calling the public API) and
# machines (agent-orchestrator minting tokens to call the AgentCore
# Gateway). One user pool, two client types.
########################################

resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-${var.environment}-users"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  mfa_configuration = var.environment == "prod" ? "OPTIONAL" : "OFF"

  admin_create_user_config {
    allow_admin_create_user_only = true # internal enterprise tool: no public self-signup
  }

  tags = var.tags
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project_name}-${var.environment}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# Custom resource server + scope so machine clients can be scoped down
# to exactly "call the agent's tools" and nothing else.
resource "aws_cognito_resource_server" "atlas_api" {
  identifier   = "atlas-api"
  name         = "Atlas platform API"
  user_pool_id = aws_cognito_user_pool.this.id

  scope {
    scope_name        = "tools.invoke"
    scope_description = "Invoke lakehouse/metadata tools via the AgentCore Gateway"
  }
}

# Public-facing app client — authorization-code flow for human users of
# the api-gateway-service.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project_name}-${var.environment}-web-client"
  user_pool_id = aws_cognito_user_pool.this.id

  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  generate_secret      = false
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# Machine-to-machine client — client_credentials flow, used only by the
# agent-orchestrator to mint short-lived tokens for AgentCore Gateway
# tool calls. Scoped to atlas-api/tools.invoke only.
resource "aws_cognito_user_pool_client" "agent_m2m" {
  name         = "${var.project_name}-${var.environment}-agent-m2m-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                     = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [aws_cognito_resource_server.atlas_api.scope_identifiers[0]]
  supported_identity_providers         = ["COGNITO"]
}
