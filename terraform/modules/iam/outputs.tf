output "app_role_arn" {
  description = "IAM role ARN to annotate on the Kubernetes service account"
  value       = aws_iam_role.app.arn
}
