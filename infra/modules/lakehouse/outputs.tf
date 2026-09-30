output "bronze_bucket_name" {
  value = aws_s3_bucket.bronze.bucket
}

output "bronze_bucket_arn" {
  value = aws_s3_bucket.bronze.arn
}

output "silver_bucket_name" {
  value = aws_s3_bucket.silver.bucket
}

output "silver_bucket_arn" {
  value = aws_s3_bucket.silver.arn
}

output "gold_bucket_name" {
  value = aws_s3_bucket.gold.bucket
}

output "gold_bucket_arn" {
  value = aws_s3_bucket.gold.arn
}

output "athena_results_bucket_name" {
  value = aws_s3_bucket.athena_results.bucket
}

output "glue_bronze_database" {
  value = aws_glue_catalog_database.bronze.name
}

output "glue_silver_database" {
  value = aws_glue_catalog_database.silver.name
}

output "glue_gold_database" {
  value = aws_glue_catalog_database.gold.name
}

output "glue_bronze_crawler_name" {
  value = aws_glue_crawler.bronze.name
}

output "glue_bronze_to_silver_job_name" {
  value = aws_glue_job.bronze_to_silver.name
}

output "glue_silver_to_gold_job_name" {
  value = aws_glue_job.silver_to_gold.name
}

output "athena_workgroup_name" {
  value = aws_athena_workgroup.agent.name
}
