variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev / staging / prod)"
  type        = string
  default     = "dev"
}

variable "app_name" {
  description = "Application name, used as prefix for all resources"
  type        = string
  default     = "hello-platform"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.small"
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (optional)"
  type        = string
  default     = ""
}

variable "nlb_dns_name" {
  description = <<-EOT
    NLB DNS name created by NGINX Ingress (Step 3 of deployment).
    Leave empty on first apply; set after NGINX deploys, then re-apply to create CloudFront.
    Obtain with:
      kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  EOT
  type        = string
  default     = ""
}

variable "waf_rate_limit" {
  description = "Max requests per 5-minute window per source IP before WAF blocks"
  type        = number
  default     = 2000
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN (us-east-1) for custom domain HTTPS. Empty = CloudFront default cert (dev only)."
  type        = string
  default     = ""
}
