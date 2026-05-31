variable "name" {
  description = "Name prefix for CloudFront resources"
  type        = string
}

variable "origin_dns_name" {
  description = <<-EOT
    NLB DNS name created by NGINX Ingress. Obtain after NGINX deploys:
      kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  EOT
  type        = string
}

variable "web_acl_arn" {
  description = "WAF WebACL ARN (CLOUDFRONT scope) from the waf module"
  type        = string
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ACM certificate ARN for a custom domain (must be in us-east-1 for CloudFront).
    When provided: SNI-only + TLSv1.2_2021 is enforced.
    When empty: CloudFront default certificate is used (*.cloudfront.net domain, TLSv1 minimum).
    Production must always provide this value.
  EOT
  type        = string
  default     = ""
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 = US/EU edges only (cheapest)."
  type        = string
  default     = "PriceClass_100"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
