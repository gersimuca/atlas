terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.30.0, < 7.0.0" # AgentCore resources need a fairly recent 6.x — check the registry if `terraform init` complains
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

########################################
# Networking
########################################

module "networking" {
  source = "../../modules/networking"

  project_name       = var.project_name
  environment        = var.environment
  availability_zones = var.availability_zones
  cluster_name       = "${var.project_name}-${var.environment}"
  single_nat_gateway = var.single_nat_gateway
  tags               = local.common_tags
}

########################################
# Security foundations (KMS, Secrets Manager, Cognito)
########################################

module "security" {
  source = "../../modules/security"

  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

########################################
# ECR
########################################

module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  kms_key_arn  = module.security.kms_key_arn
  tags         = local.common_tags
}

########################################
# Glue job role — created here (not inside the lakehouse module) so its
# policy can reference the lakehouse module's own bucket outputs without
# a circular module dependency: the role is created first with just a
# trust policy, passed into lakehouse, then granted access to the
# buckets that module creates.
########################################

resource "aws_iam_role" "glue_jobs" {
  name = "${var.project_name}-${var.environment}-glue-jobs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_jobs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

########################################
# Lakehouse
########################################

module "lakehouse" {
  source = "../../modules/lakehouse"

  project_name      = var.project_name
  environment       = var.environment
  kms_key_arn       = module.security.kms_key_arn
  glue_job_role_arn = aws_iam_role.glue_jobs.arn
  tags              = local.common_tags
}

resource "aws_iam_role_policy" "glue_jobs_lakehouse_access" {
  name = "${var.project_name}-${var.environment}-glue-lakehouse-access"
  role = aws_iam_role.glue_jobs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteAllZones"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          module.lakehouse.bronze_bucket_arn, "${module.lakehouse.bronze_bucket_arn}/*",
          module.lakehouse.silver_bucket_arn, "${module.lakehouse.silver_bucket_arn}/*",
          module.lakehouse.gold_bucket_arn, "${module.lakehouse.gold_bucket_arn}/*",
        ]
      },
      {
        Sid      = "DecryptWithPlatformKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = module.security.kms_key_arn
      },
    ]
  })
}

########################################
# Ingestion primitives — DynamoDB metadata table + SQS queue. Small
# enough not to warrant their own module.
########################################

resource "aws_dynamodb_table" "document_metadata" {
  name         = "${var.project_name}-${var.environment}-document-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "document_id"

  attribute {
    name = "document_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = module.security.kms_key_arn
  }

  point_in_time_recovery {
    enabled = var.environment == "prod"
  }

  tags = local.common_tags
}

resource "aws_sqs_queue" "ingestion_dlq" {
  name                      = "${var.project_name}-${var.environment}-ingestion-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = module.security.kms_key_arn
  tags                      = local.common_tags
}

resource "aws_sqs_queue" "ingestion_events" {
  name                       = "${var.project_name}-${var.environment}-ingestion-events"
  visibility_timeout_seconds = 120
  kms_master_key_id          = module.security.kms_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount      = 5
  })

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "ingestion_events_allow_s3" {
  queue_url = aws_sqs_queue.ingestion_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.ingestion_events.arn
      Condition = { ArnEquals = { "aws:SourceArn" = module.lakehouse.bronze_bucket_arn } }
    }]
  })
}

resource "aws_s3_bucket_notification" "bronze_upload_events" {
  bucket = module.lakehouse.bronze_bucket_name

  queue {
    queue_arn     = aws_sqs_queue.ingestion_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "documents/"
  }

  depends_on = [aws_sqs_queue_policy.ingestion_events_allow_s3]
}

########################################
# SageMaker
########################################

module "sagemaker" {
  source = "../../modules/sagemaker"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  silver_bucket_arn     = module.lakehouse.silver_bucket_arn
  kms_key_arn           = module.security.kms_key_arn
  enable_studio_domain  = var.enable_sagemaker_studio
  tags                  = local.common_tags
}

########################################
# Bedrock (Knowledge Base / RAG)
########################################

module "bedrock" {
  source = "../../modules/bedrock"

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = var.aws_region
  gold_bucket_arn     = module.lakehouse.gold_bucket_arn
  gold_bucket_name    = module.lakehouse.gold_bucket_name
  kms_key_arn         = module.security.kms_key_arn
  embedding_model_id  = var.bedrock_embedding_model_id
  vector_store_type   = var.vector_store_type
  tags                = local.common_tags
}

########################################
# AgentCore (Gateway + Memory + tool Lambdas)
########################################

module "agentcore" {
  source = "../../modules/agentcore"

  project_name                  = var.project_name
  environment                   = var.environment
  aws_region                    = var.aws_region
  kms_key_arn                   = module.security.kms_key_arn
  cognito_issuer_url            = module.security.cognito_issuer_url
  cognito_agent_m2m_client_id   = module.security.cognito_agent_m2m_client_id
  athena_workgroup_name         = module.lakehouse.athena_workgroup_name
  glue_gold_database             = module.lakehouse.glue_gold_database
  gold_bucket_arn                = module.lakehouse.gold_bucket_arn
  athena_results_bucket_arn      = "arn:aws:s3:::${module.lakehouse.athena_results_bucket_name}"
  document_metadata_table_name   = aws_dynamodb_table.document_metadata.name
  document_metadata_table_arn    = aws_dynamodb_table.document_metadata.arn
  tags                            = local.common_tags
}

resource "aws_secretsmanager_secret" "agent_m2m_credentials" {
  name       = "${var.project_name}/${var.environment}/agent-m2m-credentials"
  kms_key_id = module.security.kms_key_arn
  tags       = local.common_tags
}

resource "aws_secretsmanager_secret_version" "agent_m2m_credentials" {
  secret_id = aws_secretsmanager_secret.agent_m2m_credentials.id
  secret_string = jsonencode({
    client_id     = module.security.cognito_agent_m2m_client_id
    client_secret = module.security.cognito_agent_m2m_client_secret
    token_url     = "https://${module.security.cognito_domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
    gateway_url   = module.agentcore.gateway_url
  })
}

########################################
# EKS
########################################

module "eks" {
  source = "../../modules/eks"

  project_name        = var.project_name
  environment         = var.environment
  cluster_name        = "${var.project_name}-${var.environment}"
  cluster_version     = var.eks_cluster_version
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  public_subnet_ids   = module.networking.public_subnet_ids
  kms_key_arn         = module.security.kms_key_arn
  compute_type        = var.eks_compute_type

  # Download from:
  # https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  aws_load_balancer_controller_policy_json = file("${path.module}/aws-lb-controller-iam-policy.json")

  tags = local.common_tags
}

########################################
# Workload IRSA roles — one per app service, scoped to exactly what
# that service touches.
########################################

data "aws_iam_policy_document" "irsa_trust" {
  for_each = toset(["api-gateway-service", "agent-orchestrator", "ingestion-worker"])

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:atlas:${each.key}"]
    }
  }
}

resource "aws_iam_role" "api_gateway_service" {
  name               = "${var.project_name}-${var.environment}-api-gateway-service"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["api-gateway-service"].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "api_gateway_service" {
  name = "${var.project_name}-${var.environment}-api-gateway-service"
  role = aws_iam_role.api_gateway_service.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PresignUploadsToBronze"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${module.lakehouse.bronze_bucket_arn}/documents/*"
      },
      {
        Sid      = "ReadDocumentMetadata"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.document_metadata.arn
      },
    ]
  })
}

resource "aws_iam_role" "agent_orchestrator" {
  name               = "${var.project_name}-${var.environment}-agent-orchestrator"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["agent-orchestrator"].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "agent_orchestrator" {
  name = "${var.project_name}-${var.environment}-agent-orchestrator"
  role = aws_iam_role.agent_orchestrator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConverseWithClaude"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:ApplyGuardrail"]
        Resource = "*"
      },
      {
        Sid      = "RetrieveFromKnowledgeBase"
        Effect   = "Allow"
        Action   = ["bedrock:Retrieve"]
        Resource = module.bedrock.knowledge_base_arn
      },
      {
        # Direct-mode tool execution (local/dev path — see ToolExecutor
        # in the agent-orchestrator app). Production mode routes these
        # same operations through the AgentCore Gateway instead.
        Sid    = "DirectModeLakehouseAndMetadataAccess"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
          "glue:GetTable", "glue:GetTables", "glue:GetDatabase",
          "dynamodb:GetItem", "dynamodb:Query",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadGoldAndAthenaResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
        Resource = ["${module.lakehouse.gold_bucket_arn}", "${module.lakehouse.gold_bucket_arn}/*"]
      },
      {
        # Scoped, best-effort action set for the AgentCore Memory data
        # plane — verify exact action names in the IAM action reference
        # for bedrock-agentcore before relying on this in production.
        Sid      = "AgentCoreMemoryReadWrite"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:CreateEvent", "bedrock-agentcore:ListEvents", "bedrock-agentcore:GetMemory", "bedrock-agentcore:ListMemories"]
        Resource = "*"
      },
      {
        Sid      = "ReadM2MCredentialsForGatewayCalls"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.agent_m2m_credentials.arn
      },
      {
        Sid      = "DecryptWithPlatformKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = module.security.kms_key_arn
      },
    ]
  })
}

resource "aws_iam_role" "ingestion_worker" {
  name               = "${var.project_name}-${var.environment}-ingestion-worker"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["ingestion-worker"].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "ingestion_worker" {
  name = "${var.project_name}-${var.environment}-ingestion-worker"
  role = aws_iam_role.ingestion_worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeIngestionQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.ingestion_events.arn
      },
      {
        Sid      = "WriteDocumentMetadata"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.document_metadata.arn
      },
      {
        Sid      = "ReadBronzeStartGlueJobs"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "glue:StartCrawler", "glue:StartJobRun", "glue:GetCrawler", "glue:GetJobRun"]
        Resource = "*"
      },
      {
        Sid      = "InvokeClassifierEndpoint"
        Effect   = "Allow"
        Action   = ["sagemaker:InvokeEndpoint"]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${var.project_name}-${var.environment}-*"
      },
    ]
  })
}

########################################
# Kubernetes / Helm providers — configured against the cluster this
# same apply just created. Cluster addons (LB controller, metrics
# server, external-secrets, Karpenter) live here rather than inside the
# eks module so this dependency is explicit instead of hidden behind
# provider passthrough.
########################################

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.9.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.lb_controller_role_arn
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.networking.vpc_id
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "kube-system"
  version    = "0.10.4"
}

resource "helm_release" "karpenter" {
  count      = var.eks_compute_type == "managed_node_group" ? 1 : 0
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter/karpenter"
  chart      = "karpenter"
  namespace  = "kube-system"
  version    = "1.1.1"

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.karpenter_controller_role_arn
  }
  # NodePool / EC2NodeClass CRDs are applied separately (see
  # k8s/karpenter/) once the controller above is running — they're
  # workload config, not cluster infrastructure, so they stay out of
  # Terraform's blast radius.
}
