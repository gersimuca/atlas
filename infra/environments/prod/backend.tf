# Same bootstrap as dev (see PREREQUISITES.md) — a separate state file
# and lock table entry, same bucket/table.

terraform {
  backend "s3" {
    bucket         = "atlas-tfstate-REPLACE_WITH_YOUR_ACCOUNT_ID"
    key            = "atlas-platform/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "atlas-tfstate-lock"
    encrypt        = true
  }
}
