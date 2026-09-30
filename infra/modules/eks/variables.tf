variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version. Check `aws eks describe-addon-versions` or the console for the current supported range before applying — this drifts every few months."
  type        = string
  default     = "1.34"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "kms_key_arn" {
  description = "CMK used for envelope encryption of Kubernetes Secrets at rest."
  type        = string
}

variable "compute_type" {
  description = "How pods get compute: \"fargate\" (serverless, scales to zero, no idle node cost — used for dev) or \"managed_node_group\" (EC2 capacity managed by Karpenter — used for prod, needed for DaemonSets/host networking/predictable steady-state cost)."
  type        = string
  default     = "fargate"

  validation {
    condition     = contains(["fargate", "managed_node_group"], var.compute_type)
    error_message = "compute_type must be \"fargate\" or \"managed_node_group\"."
  }
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m6i.large", "m6a.large"]
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "aws_load_balancer_controller_policy_json" {
  description = <<-EOT
    IAM policy JSON for the AWS Load Balancer Controller. Not vendored in
    this repo because AWS revises it periodically — download the current
    version before first apply:
      curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
    and pass its contents in via -var-file or `file("iam-policy.json")`.
  EOT
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
