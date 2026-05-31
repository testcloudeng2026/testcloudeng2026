output "dev_account_id" {
  description = "AWS Account ID for the dev environment"
  value       = aws_organizations_account.dev.id
}

output "prod_account_id" {
  description = "AWS Account ID for the prod environment"
  value       = aws_organizations_account.prod.id
}

output "organization_id" {
  description = "AWS Organization ID"
  value       = data.aws_organizations_organization.this.id
}
