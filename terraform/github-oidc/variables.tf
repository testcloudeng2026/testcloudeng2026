variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  description = "Project name — used as suffix on role names to avoid collisions"
  type        = string
  default     = "hello-platform"
}

variable "github_repo" {
  description = "GitHub repo in owner/repo format (e.g. natleomol/testcloudeng2026)"
  type        = string
}

variable "state_bucket_name" {
  description = "S3 state bucket name from bootstrap output"
  type        = string
}

variable "dynamodb_table_name" {
  description = "DynamoDB lock table name from bootstrap output"
  type        = string
  default     = "hello-platform-tfstate-lock"
}
