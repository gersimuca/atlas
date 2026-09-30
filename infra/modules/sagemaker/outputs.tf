output "execution_role_arn" {
  value = aws_iam_role.sagemaker_execution.arn
}

output "model_artifacts_bucket_name" {
  value = aws_s3_bucket.model_artifacts.bucket
}

output "model_package_group_name" {
  value = aws_sagemaker_model_package_group.document_classifier.model_package_group_name
}

output "studio_domain_id" {
  value = var.enable_studio_domain ? aws_sagemaker_domain.this[0].id : null
}
