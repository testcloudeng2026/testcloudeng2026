variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev / staging / prod)"
  type        = string
  default     = "prod"
}

variable "app_name" {
  description = "Application name, used as prefix for all resources"
  type        = string
  default     = "hello-platform"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (optional)"
  type        = string
  default     = ""
}

variable "waf_rate_limit" {
  description = "Max requests per 5-minute window per source IP before WAF blocks"
  type        = number
  default     = 1000
}
