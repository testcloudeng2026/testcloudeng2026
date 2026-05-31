locals {
  origin_id = "nlb-nginx-origin"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name} — WAF-protected edge for NGINX/NLB origin"
  price_class     = var.price_class

  # ── Origin: NGINX NLB ──────────────────────────────────────────────────────
  origin {
    domain_name = var.origin_dns_name
    origin_id   = local.origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ── Default cache behaviour ────────────────────────────────────────────────
  # TTL 0 everywhere: this is an API, not a static site. No caching at edge.
  # CloudFront still provides WAF inspection and Shield Standard.
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization", "X-Forwarded-For"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # ── TLS ────────────────────────────────────────────────────────────────────
  # minimum_protocol_version conflicts with cloudfront_default_certificate — they
  # are mutually exclusive in the AWS provider. TLSv1.2_2021 is only enforceable
  # when a custom ACM certificate is supplied.
  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == "" ? true : null
    acm_certificate_arn            = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    ssl_support_method             = var.acm_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.acm_certificate_arn != "" ? "TLSv1.2_2021" : null
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # ── WAF association ────────────────────────────────────────────────────────
  # WAFv2 ARN is passed here. CloudFront inspects every request against the
  # WebACL before forwarding to the NLB origin.
  web_acl_id = var.web_acl_arn

  tags = var.tags
}
