# Before your first `terraform apply` here

Two manual, one-time steps. Both are things Terraform can't safely do
for itself (bootstrap its own state backend) or shouldn't do for you
silently (pull a third-party IAM policy at apply time).

## 1. Create the remote state backend

```bash
aws s3api create-bucket --bucket atlas-tfstate-<your-account-id> --region us-east-1
aws s3api put-bucket-versioning --bucket atlas-tfstate-<your-account-id> \
    --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name atlas-tfstate-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
```

Then edit `backend.tf` to point at your actual bucket name.

## 2. Fetch the current AWS Load Balancer Controller IAM policy

`aws-lb-controller-iam-policy.json` in this folder is a placeholder —
AWS revises the real policy from time to time as the controller gains
features, so it isn't vendored here. Replace it with the current
version:

```bash
curl -o aws-lb-controller-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

## 3. Enable Bedrock model access

Bedrock model access is opt-in per account/region. In the console:
**Bedrock → Model access → Enable** for at least the Claude model
referenced by `var.bedrock_model_id` and the Titan embedding model.
This can't be done via Terraform.

## 4. Then

```bash
terraform init
terraform plan
terraform apply
```

Expect this to take 15–20 minutes, mostly waiting on the EKS control
plane and the OpenSearch Serverless collection.
