terraform {
  required_providers {
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "this" {
  private_key_pem = tls_private_key.this.private_key_pem

  subject {
    common_name = var.common_name
  }

  validity_period_hours = 17520 # 2 years

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "this" {
  private_key      = tls_private_key.this.private_key_pem
  certificate_body = tls_self_signed_cert.this.cert_pem

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}
