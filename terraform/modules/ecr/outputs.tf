output "repository_url" {
  description = "ECR repository URL (used for docker push and k8s image reference)"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.this.arn
}
