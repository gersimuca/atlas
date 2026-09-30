variable "project_name" {
  description = "Short project name used as a prefix for all resource names/tags."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev, prod."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets across. 2 is enough for dev, use 3 for prod."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper, single point of failure) instead of one per AZ. Recommended true for dev, false for prod."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "EKS cluster name, used to tag subnets for the AWS Load Balancer Controller and cluster-autoscaler/Karpenter auto-discovery."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
