output "certificate_arn" {
  description = "ARN of the imported ACM certificate"
  value       = aws_acm_certificate.this.arn
}
