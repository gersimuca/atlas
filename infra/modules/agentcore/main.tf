data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
}

########################################
# Lambda tools — small, single-purpose functions that the AgentCore
# Gateway exposes to the agent as MCP tools. Each gets its own
# least-privilege role rather than sharing one broad "tools" role.
########################################

data "archive_file" "query_lakehouse" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/query-lakehouse-tool"
  output_path = "${path.module}/.build/query-lakehouse-tool.zip"
}

data "archive_file" "get_document_metadata" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/get-document-metadata-tool"
  output_path = "${path.module}/.build/get-document-metadata-tool.zip"
}

resource "aws_iam_role" "query_lakehouse_lambda" {
  name = "${local.name}-query-lakehouse-tool"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "query_lakehouse_lambda" {
  name = "${local.name}-query-lakehouse-tool"
  role = aws_iam_role.query_lakehouse_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunReadOnlyAthenaQueries"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
        ]
        Resource = "arn:aws:athena:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workgroup/${var.athena_workgroup_name}"
      },
      {
        Sid      = "ReadGlueCatalogForGoldDb"
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetPartitions"]
        Resource = "*"
      },
      {
        Sid      = "ReadGoldDataAndWriteQueryResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
        Resource = [var.gold_bucket_arn, "${var.gold_bucket_arn}/*", var.athena_results_bucket_arn, "${var.athena_results_bucket_arn}/*"]
      },
      {
        Sid      = "DecryptWithPlatformKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "query_lakehouse" {
  function_name    = "${local.name}-query-lakehouse-tool"
  role             = aws_iam_role.query_lakehouse_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.query_lakehouse.output_path
  source_code_hash = data.archive_file.query_lakehouse.output_base64sha256

  environment {
    variables = {
      GLUE_DATABASE        = var.glue_gold_database
      ATHENA_WORKGROUP     = var.athena_workgroup_name
      ATHENA_OUTPUT_S3_URI = "s3://${replace(var.athena_results_bucket_arn, "arn:aws:s3:::", "")}/agent/"
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "get_metadata_lambda" {
  name = "${local.name}-get-document-metadata-tool"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "get_metadata_lambda" {
  name = "${local.name}-get-document-metadata-tool"
  role = aws_iam_role.get_metadata_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDocumentMetadataTable"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = [var.document_metadata_table_arn, "${var.document_metadata_table_arn}/index/*"]
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "get_document_metadata" {
  function_name    = "${local.name}-get-document-metadata-tool"
  role             = aws_iam_role.get_metadata_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.get_document_metadata.output_path
  source_code_hash = data.archive_file.get_document_metadata.output_base64sha256

  environment {
    variables = {
      METADATA_TABLE_NAME = var.document_metadata_table_name
    }
  }

  tags = var.tags
}

########################################
# AgentCore Memory — session/conversation persistence, so the
# agent-orchestrator (stateless, horizontally scaled on EKS) doesn't
# need sticky sessions or its own Redis just to remember a conversation
# across pod restarts or replicas.
########################################

resource "aws_iam_role" "agentcore_memory" {
  name = "${local.name}-agentcore-memory"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "agentcore_memory" {
  role       = aws_iam_role.agentcore_memory.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy"
}

resource "aws_bedrockagentcore_memory" "sessions" {
  name                      = replace("${local.name}_sessions", "-", "_")
  description               = "Conversation memory for the Atlas agent-orchestrator"
  event_expiry_duration     = var.memory_event_expiry_days
  encryption_key_arn        = var.kms_key_arn
  memory_execution_role_arn = aws_iam_role.agentcore_memory.arn

  tags = var.tags
}

########################################
# AgentCore Gateway — converts the two Lambda tools above into
# MCP-compatible tools with centralized JWT-based authorization, so
# every tool call is authenticated, authorized, and audited in one
# place instead of each service having its own ad-hoc AWS credentials
# for Athena/DynamoDB access.
#
# NOTE: aws_bedrockagentcore_gateway_target's target_configuration
# block is one of the newest corners of the AWS provider at the time
# this was written — confirm the current attribute names in the
# hashicorp/aws provider docs before applying; the shape below is a
# best-effort based on the Gateway/Lambda integration pattern AWS
# documents for AgentCore.
########################################

resource "aws_iam_role" "agentcore_gateway" {
  name = "${local.name}-agentcore-gateway"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "agentcore_gateway" {
  name = "${local.name}-agentcore-gateway"
  role = aws_iam_role.agentcore_gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeToolLambdas"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.query_lakehouse.arn, aws_lambda_function.get_document_metadata.arn]
    }]
  })
}

resource "aws_bedrockagentcore_gateway" "tools" {
  name            = "${local.name}-tools-gateway"
  role_arn        = aws_iam_role.agentcore_gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = "${var.cognito_issuer_url}/.well-known/openid-configuration"
      allowed_clients = [var.cognito_agent_m2m_client_id]
    }
  }

  tags = var.tags
}

resource "aws_bedrockagentcore_gateway_target" "query_lakehouse" {
  gateway_identifier = aws_bedrockagentcore_gateway.tools.id
  name               = "query-lakehouse"

  target_configuration {
    lambda {
      lambda_arn = aws_lambda_function.query_lakehouse.arn

      tool_schema {
        name        = "query_lakehouse"
        description = "Run a read-only SQL SELECT against the curated gold-zone lakehouse tables via Athena. Use for aggregate, numeric, or structured questions."
        input_schema = jsonencode({
          type       = "object"
          properties = { sql = { type = "string", description = "A single SELECT statement" } }
          required   = ["sql"]
        })
      }
    }
  }

  credential_provider_configuration {
    credential_provider_type = "IAM"
  }
}

resource "aws_bedrockagentcore_gateway_target" "get_document_metadata" {
  gateway_identifier = aws_bedrockagentcore_gateway.tools.id
  name               = "get-document-metadata"

  target_configuration {
    lambda {
      lambda_arn = aws_lambda_function.get_document_metadata.arn

      tool_schema {
        name        = "get_document_metadata"
        description = "Fetch metadata (type, department, upload date, processing status) for a specific document by its document_id."
        input_schema = jsonencode({
          type       = "object"
          properties = { document_id = { type = "string" } }
          required   = ["document_id"]
        })
      }
    }
  }

  credential_provider_configuration {
    credential_provider_type = "IAM"
  }
}
