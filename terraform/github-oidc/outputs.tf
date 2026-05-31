output "ci_role_arn" {
  description = "Set as GitHub secret AWS_CI_ROLE_ARN"
  value       = aws_iam_role.ci.arn
}

output "deploy_role_arn" {
  description = "Set as GitHub secret AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}
