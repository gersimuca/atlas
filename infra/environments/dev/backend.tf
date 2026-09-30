# Remote state — create the bucket and lock table once, by hand or via
# a tiny bootstrap config, *before* anyone runs `terraform init` here.
# (Chicken-and-egg: Terraform can't create the backend it's about to
# store its own state in.)
#
#   aws s3api create-bucket --bucket atlas-tfstate-<your-account-id> --region us-east-1
#   aws s3api put-bucket-versioning --bucket atlas-tfstate-<your-account-id> \
#       --versioning-configuration Status=Enabled
#   aws dynamodb create-table --table-name atlas-tfstate-lock \
#       --attribute-definitions AttributeName=LockID,AttributeType=S \
#       --key-schema AttributeName=LockID,KeyType=HASH \
#       --billing-mode PAY_PER_REQUEST

terraform {
  backend "s3" {
    bucket         = "atlas-tfstate-REPLACE_WITH_YOUR_ACCOUNT_ID"
    key            = "atlas-platform/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "atlas-tfstate-lock"
    encrypt        = true
  }
}
