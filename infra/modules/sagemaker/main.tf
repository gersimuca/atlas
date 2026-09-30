data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
}

########################################
# Model artifact bucket — training job outputs, evaluation reports.
# Separate from the lakehouse buckets because its lifecycle (versioned
# model.tar.gz artifacts) is different from medallion document data.
########################################

resource "aws_s3_bucket" "model_artifacts" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}-ml-artifacts"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "model_artifacts" {
  bucket                  = aws_s3_bucket.model_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########################################
# Execution role — used by training jobs, processing jobs, and every
# step of the SageMaker Pipeline (defined in ml/sagemaker/pipeline/,
# deployed via the SDK rather than Terraform — see that file's header
# comment for why).
########################################

resource "aws_iam_role" "sagemaker_execution" {
  name = "${local.name}-sagemaker-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "sagemaker_execution" {
  name = "${local.name}-sagemaker-execution"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTrainingDataWriteArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [var.silver_bucket_arn, "${var.silver_bucket_arn}/*"]
      },
      {
        Sid      = "ReadWriteModelArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.model_artifacts.arn, "${aws_s3_bucket.model_artifacts.arn}/*"]
      },
      {
        Sid    = "TrainingAndProcessingJobLifecycle"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob", "sagemaker:StopTrainingJob",
          "sagemaker:CreateProcessingJob", "sagemaker:DescribeProcessingJob", "sagemaker:StopProcessingJob",
          "sagemaker:CreateModel", "sagemaker:CreateEndpointConfig", "sagemaker:CreateEndpoint",
          "sagemaker:UpdateEndpoint", "sagemaker:DescribeEndpoint",
        ]
        Resource = "*"
      },
      {
        Sid      = "WriteLogsAndMetrics"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid      = "DecryptWithPlatformKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:CreateGrant"]
        Resource = var.kms_key_arn
      },
      {
        Sid      = "PassSelfToSageMakerServices"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-sagemaker-execution"
      },
    ]
  })
}

########################################
# Model registry — the SageMaker Pipeline's RegisterModel step approves
# new document-classifier versions into this group; the ingestion
# worker (or a small deploy job) promotes the latest "Approved" version
# to the live endpoint.
########################################

resource "aws_sagemaker_model_package_group" "document_classifier" {
  model_package_group_name        = "${local.name}-document-classifier"
  model_package_group_description = "Registry for the document classifier used to auto-tag incoming documents during ingestion."
  tags                             = var.tags
}

########################################
# SageMaker Studio domain — optional, off by default (see variable doc).
# For interactive EDA/experimentation only; the training pipeline itself
# runs as jobs against the execution role above and never needs this.
########################################

resource "aws_sagemaker_domain" "this" {
  count       = var.enable_studio_domain ? 1 : 0
  domain_name = "${local.name}-studio"
  auth_mode   = "IAM"
  vpc_id      = var.vpc_id
  subnet_ids  = var.private_subnet_ids

  default_user_settings {
    execution_role = aws_iam_role.sagemaker_execution.arn
  }

  kms_key_id = var.kms_key_arn
  tags       = var.tags
}

resource "aws_sagemaker_user_profile" "default" {
  count             = var.enable_studio_domain ? 1 : 0
  domain_id         = aws_sagemaker_domain.this[0].id
  user_profile_name = "atlas-engineer"

  user_settings {
    execution_role = aws_iam_role.sagemaker_execution.arn
  }

  tags = var.tags
}
