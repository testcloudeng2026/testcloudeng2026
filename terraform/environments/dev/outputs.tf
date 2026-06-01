output "ecr_repository_url" {
  description = "ECR repository URL — use for docker push and k8s/deployment.yaml image reference"
  value       = module.ecr.repository_url
}

output "eks_cluster_name" {
  description = "EKS cluster name — use with: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "app_role_arn" {
  description = "IRSA role ARN — annotate on k8s/serviceaccount.yaml"
  value       = module.iam.app_role_arn
}

output "vpc_id" {
  description = "VPC ID — required for AWS Load Balancer Controller"
  value       = module.networking.vpc_id
}

output "lbc_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = module.iam_lbc.role_arn
}

output "waf_web_acl_arn" {
  description = "WAF WebACL ARN (REGIONAL scope — attached to ALB)"
  value       = module.waf.web_acl_arn
}

output "log_group_name" {
  description = "CloudWatch log group for application logs"
  value       = module.observability.log_group_name
}

output "kms_eks_key_arn" {
  description = "KMS key ARN used for EKS secrets envelope encryption"
  value       = module.kms_eks.key_arn
}
