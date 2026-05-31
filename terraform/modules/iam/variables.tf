variable "name" {
  description = "Name prefix for IAM resources"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL (without https:// prefix)"
  type        = string
}

variable "k8s_namespace" {
  description = "Kubernetes namespace for the app service account"
  type        = string
  default     = "hello-platform"
}

variable "k8s_service_account" {
  description = "Kubernetes service account name that will assume this role"
  type        = string
  default     = "hello-platform"
}

variable "ssm_parameter_prefix" {
  description = "SSM parameter path prefix the app is allowed to read"
  type        = string
  default     = "/hello-platform"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
