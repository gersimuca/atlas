data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
}

########################################
# Vector store — OpenSearch Serverless collection dedicated to this
# knowledge base. See the vector_store_type variable docstring for the
# S3 Vectors cost trade-off before deploying this for real.
########################################

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-kb-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.name}-kb"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-kb-net"
  type = "network"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.name}-kb"]
    }]
    # Bedrock reaches the collection over the AWS-internal service
    # path, not the public internet — tighten to a VPC endpoint-only
    # policy once this collection also needs direct developer access.
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_collection" "kb" {
  name = "${local.name}-kb"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]

  tags = var.tags
}

resource "aws_opensearchserverless_access_policy" "kb" {
  name = "${local.name}-kb-access"
  type = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${aws_opensearchserverless_collection.kb.name}/*"]
        Permission   = ["aoss:*"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${aws_opensearchserverless_collection.kb.name}"]
        Permission   = ["aoss:*"]
      },
    ]
    Principal = [aws_iam_role.knowledge_base.arn]
  }])
}

########################################
# IAM role Bedrock assumes to read the S3 data source, write into the
# vector store, and call the embedding model.
########################################

resource "aws_iam_role" "knowledge_base" {
  name = "${local.name}-bedrock-kb"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:knowledge-base/*" }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "knowledge_base" {
  name = "${local.name}-bedrock-kb"
  role = aws_iam_role.knowledge_base.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadGoldZone"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [var.gold_bucket_arn, "${var.gold_bucket_arn}/*"]
      },
      {
        Sid      = "InvokeEmbeddingModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embedding_model_id}"
      },
      {
        Sid      = "OpenSearchServerlessAccess"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = aws_opensearchserverless_collection.kb.arn
      },
      {
        Sid      = "DecryptWithPlatformKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

########################################
# Guardrail — applied by the agent-orchestrator on every Converse call.
# Content filters catch the categories every enterprise deployment
# should have on by default; denied_topic below is an illustrative
# example, extend per your actual compliance requirements.
########################################

resource "aws_bedrock_guardrail" "this" {
  name                      = "${local.name}-guardrail"
  blocked_input_messaging   = "I can't help with that request."
  blocked_outputs_messaging = "I can't provide that response — let me know if I can help with something else about your documents."

  content_policy_config {
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE" # prompt-attack filtering only applies to input
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
  }

  topic_policy_config {
    topics_config {
      name       = "legal-advice"
      type       = "DENY"
      definition = "Providing specific legal advice or opinions about contract enforceability rather than summarizing what a document says."
    }
  }

  tags = var.tags
}

resource "aws_bedrock_guardrail_version" "published" {
  guardrail_arn = aws_bedrock_guardrail.this.guardrail_arn
  description   = "Published from Terraform for environment=${var.environment}"
}

########################################
# Knowledge base + S3 data source
########################################

resource "aws_bedrockagent_knowledge_base" "this" {
  name     = "${local.name}-kb"
  role_arn = aws_iam_role.knowledge_base.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embedding_model_id}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = "${var.project_name}-index"

      field_mapping {
        vector_field   = "embedding"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }

  tags = var.tags

  depends_on = [aws_opensearchserverless_access_policy.kb]
}

resource "aws_bedrockagent_data_source" "gold_documents" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  name              = "${local.name}-gold-documents"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = var.gold_bucket_arn
      inclusion_prefixes = ["documents/"]
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }
}
