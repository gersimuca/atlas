data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_prefix = "${var.project_name}-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

########################################
# S3 — medallion zones
########################################

resource "aws_s3_bucket" "bronze" {
  bucket = "${local.bucket_prefix}-bronze"
  tags   = merge(var.tags, { Zone = "bronze" })
}

resource "aws_s3_bucket" "silver" {
  bucket = "${local.bucket_prefix}-silver"
  tags   = merge(var.tags, { Zone = "silver" })
}

resource "aws_s3_bucket" "gold" {
  bucket = "${local.bucket_prefix}-gold"
  tags   = merge(var.tags, { Zone = "gold" })
}

resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.bucket_prefix}-athena-results"
  tags   = var.tags
}

resource "aws_s3_bucket" "glue_scripts" {
  bucket = "${local.bucket_prefix}-glue-scripts"
  tags   = var.tags
}

# Apply the same baseline (versioning, KMS encryption, block public
# access) to every bucket in the lakehouse.
locals {
  all_buckets = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    athena_results = aws_s3_bucket.athena_results.id
    glue_scripts   = aws_s3_bucket.glue_scripts.id
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.all_buckets
  bucket   = each.value
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.all_buckets
  bucket   = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = local.all_buckets
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    id     = "archive-raw-after-retention-window"
    status = "Enabled"
    filter {}

    transition {
      days          = var.raw_zone_retention_days
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-old-query-results"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
  }
}

########################################
# Glue Data Catalog — one database per medallion zone
########################################

resource "aws_glue_catalog_database" "bronze" {
  name        = "${var.project_name}_${var.environment}_bronze"
  description = "Raw documents as landed, catalogued by the bronze crawler."
}

resource "aws_glue_catalog_database" "silver" {
  name        = "${var.project_name}_${var.environment}_silver"
  description = "Cleaned, deduplicated documents as Iceberg tables."
}

resource "aws_glue_catalog_database" "gold" {
  name        = "${var.project_name}_${var.environment}_gold"
  description = "Business-level aggregates, queried directly by Athena and the agent's query_lakehouse tool."
}

resource "aws_glue_crawler" "bronze" {
  name          = "${var.project_name}-${var.environment}-bronze-crawler"
  database_name = aws_glue_catalog_database.bronze.name
  role          = var.glue_job_role_arn

  s3_target {
    path = "s3://${aws_s3_bucket.bronze.bucket}/documents/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  # Runs nightly; the ingestion worker can also trigger it on-demand for
  # a freshly-landed batch via glue:StartCrawler.
  schedule = "cron(0 2 * * ? *)"
  tags     = var.tags
}

########################################
# Glue ETL jobs — scripts are authored in data-pipelines/glue-jobs/ and
# uploaded to S3 here, so `terraform apply` always deploys whatever is
# checked into the repo.
########################################

resource "aws_s3_object" "bronze_to_silver_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "jobs/bronze_to_silver.py"
  source = "${path.root}/../../../data-pipelines/glue-jobs/bronze_to_silver.py"
  etag   = filemd5("${path.root}/../../../data-pipelines/glue-jobs/bronze_to_silver.py")
}

resource "aws_s3_object" "silver_to_gold_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "jobs/silver_to_gold.py"
  source = "${path.root}/../../../data-pipelines/glue-jobs/silver_to_gold.py"
  etag   = filemd5("${path.root}/../../../data-pipelines/glue-jobs/silver_to_gold.py")
}

resource "aws_glue_job" "bronze_to_silver" {
  name              = "${var.project_name}-${var.environment}-bronze-to-silver"
  role_arn          = var.glue_job_role_arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = var.environment == "prod" ? 5 : 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/${aws_s3_object.bronze_to_silver_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--datalake-formats"                 = "iceberg"
    "--bronze_database"                  = aws_glue_catalog_database.bronze.name
    "--bronze_table"                     = "documents"
    "--silver_database"                  = aws_glue_catalog_database.silver.name
    "--silver_table_s3_path"             = "s3://${aws_s3_bucket.silver.bucket}/documents/"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.bucket}/temp/"
  }

  tags = var.tags
}

resource "aws_glue_job" "silver_to_gold" {
  name              = "${var.project_name}-${var.environment}-silver-to-gold"
  role_arn          = var.glue_job_role_arn
  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = var.environment == "prod" ? 5 : 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/${aws_s3_object.silver_to_gold_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--datalake-formats"                 = "iceberg"
    "--silver_database"                  = aws_glue_catalog_database.silver.name
    "--gold_database"                    = aws_glue_catalog_database.gold.name
    "--gold_table_s3_path"                = "s3://${aws_s3_bucket.gold.bucket}/"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.bucket}/temp/"
  }

  tags = var.tags
}

########################################
# Athena workgroup — isolates the agent's ad-hoc queries (own query
# result location, per-query byte limit as a cost guardrail) from any
# analyst/BI workgroup you'd add later.
########################################

resource "aws_athena_workgroup" "agent" {
  name = "${var.project_name}-${var.environment}-agent"

  configuration {
    enforce_workgroup_configuration    = true
    bytes_scanned_cutoff_per_query     = 5 * 1024 * 1024 * 1024 # 5 GB safety cap per query

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/agent/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn        = var.kms_key_arn
      }
    }
  }

  tags = var.tags
}

########################################
# Lake Formation — minimal governance baseline: register the bucket
# locations so Lake Formation (not raw S3/IAM policy) becomes the source
# of truth for fine-grained table/column grants as the platform grows.
########################################

resource "aws_lakeformation_resource" "silver" {
  arn = aws_s3_bucket.silver.arn
}

resource "aws_lakeformation_resource" "gold" {
  arn = aws_s3_bucket.gold.arn
}

resource "aws_lakeformation_permissions" "glue_role_silver" {
  principal   = var.glue_job_role_arn
  permissions = ["ALL"]

  database {
    name = aws_glue_catalog_database.silver.name
  }
}

resource "aws_lakeformation_permissions" "glue_role_gold" {
  principal   = var.glue_job_role_arn
  permissions = ["ALL"]

  database {
    name = aws_glue_catalog_database.gold.name
  }
}
