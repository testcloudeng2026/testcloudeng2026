output "web_acl_arn" {
  description = "WAF WebACL ARN — annotated on the ALB Ingress via alb.ingress.kubernetes.io/wafv2-acl-arn"
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "WAF WebACL ID"
  value       = aws_wafv2_web_acl.this.id
}
