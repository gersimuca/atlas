data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

########################################
# EKS cluster
#
# Hand-rolling an EKS control plane + node groups + IRSA + addon
# versions from scratch is a lot of boilerplate with little additional
# learning value over just reading the docs — so unlike networking,
# lakehouse, bedrock, and agentcore (which are bespoke to this project
# and written by hand below), the cluster itself leans on the
# community-maintained terraform-aws-modules/eks/aws module. It is the
# de-facto standard for this in real teams, and knowing when to reach
# for a vetted module instead of re-deriving it is itself part of the
# job.
########################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0" # tracks AWS provider v6.x — check the registry for newer majors before bumping

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  endpoint_public_access  = true # simplest for a portfolio demo; in a real prod account, put this behind a VPN/bastion and set false
  enable_cluster_creator_admin_permissions = true

  encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }

  # Core add-ons managed by EKS itself (not Helm) — CNI, DNS, kube-proxy,
  # and the EBS CSI driver for any PVCs.
  addons = {
    vpc-cni    = { most_recent = true }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  fargate_profiles = var.compute_type == "fargate" ? {
    default = {
      name = "${var.cluster_name}-default"
      selectors = [
        { namespace = "atlas" },
        { namespace = "kube-system" },
      ]
      subnet_ids = var.private_subnet_ids
    }
  } : {}

  eks_managed_node_groups = var.compute_type == "managed_node_group" ? {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      capacity_type  = "ON_DEMAND"
      labels         = { workload = "atlas-platform" }
      # Karpenter takes over day-2 scaling once bootstrapped; this
      # managed group only needs to run Karpenter's own controller pods.
      tags = { "karpenter.sh/discovery" = var.cluster_name }
    }
  } : {}

  tags = var.tags
}

########################################
# EBS CSI driver IRSA role (needed regardless of compute_type for any
# PersistentVolumeClaims, e.g. LocalStack-style stateful add-ons)
########################################

data "aws_iam_policy_document" "ebs_csi_assume" {
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
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

########################################
# AWS Load Balancer Controller — IRSA role only. The Helm release itself
# lives in the environment root module, next to the kubernetes/helm
# provider blocks that depend on this cluster existing.
########################################

data "aws_iam_policy_document" "lb_controller_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.project_name}-${var.environment}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume.json
  tags               = var.tags
}

resource "aws_iam_policy" "lb_controller" {
  name   = "${var.project_name}-${var.environment}-lb-controller"
  policy = var.aws_load_balancer_controller_policy_json
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

########################################
# Karpenter IAM — controller role (IRSA) + the node role Karpenter
# launches EC2 instances with. Only needed on the managed_node_group
# path; Fargate has no node autoscaling to do.
#
# Not covered here: the SQS interruption queue + EventBridge rules for
# graceful spot-interruption draining. Add those (see the Karpenter
# docs' "getting started" CloudFormation/Terraform) before relying on
# spot capacity in a real prod cluster.
########################################

data "aws_iam_policy_document" "karpenter_controller_assume" {
  count = var.compute_type == "managed_node_group" ? 1 : 0

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
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  count              = var.compute_type == "managed_node_group" ? 1 : 0
  name               = "${var.project_name}-${var.environment}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "karpenter_controller" {
  count = var.compute_type == "managed_node_group" ? 1 : 0
  name  = "${var.project_name}-${var.environment}-karpenter-controller"
  role  = aws_iam_role.karpenter_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2InstanceLifecycle"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate", "ec2:RunInstances", "ec2:TerminateInstances",
          "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeImages",
          "ec2:DescribeLaunchTemplates", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory", "ec2:DescribeAvailabilityZones",
          "ssm:GetParameter", "pricing:GetProducts", "eks:DescribeCluster",
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowPassingNodeRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node[0].arn
      },
    ]
  })
}

resource "aws_iam_role" "karpenter_node" {
  count = var.compute_type == "managed_node_group" ? 1 : 0
  name  = "${var.project_name}-${var.environment}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_instance_profile" "karpenter_node" {
  count = var.compute_type == "managed_node_group" ? 1 : 0
  name  = "${var.project_name}-${var.environment}-karpenter-node"
  role  = aws_iam_role.karpenter_node[0].name
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = var.compute_type == "managed_node_group" ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])

  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = each.value
}
