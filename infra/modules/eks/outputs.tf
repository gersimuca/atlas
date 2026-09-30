output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "lb_controller_role_arn" {
  value = aws_iam_role.lb_controller.arn
}

output "karpenter_controller_role_arn" {
  value = var.compute_type == "managed_node_group" ? aws_iam_role.karpenter_controller[0].arn : null
}

output "karpenter_node_instance_profile_name" {
  value = var.compute_type == "managed_node_group" ? aws_iam_instance_profile.karpenter_node[0].name : null
}

output "karpenter_node_role_arn" {
  value = var.compute_type == "managed_node_group" ? aws_iam_role.karpenter_node[0].arn : null
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}
