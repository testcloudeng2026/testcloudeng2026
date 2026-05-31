region             = "us-east-1"
environment        = "prod"
app_name           = "hello-platform"
node_instance_type = "t3.medium"
alarm_email        = ""

# Set after NGINX Ingress deploys and creates the NLB, then re-run terraform apply.
nlb_dns_name   = ""
waf_rate_limit = 1000

# ACM certificate ARN (must be in us-east-1 for CloudFront).
acm_certificate_arn = ""
