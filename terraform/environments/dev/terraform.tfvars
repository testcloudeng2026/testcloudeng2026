region             = "us-east-1"
environment        = "dev"
app_name           = "hello-platform"
node_instance_type = "t3.small"
alarm_email        = ""

# Set after NGINX Ingress deploys and creates the NLB, then re-run terraform apply.
# kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
nlb_dns_name   = ""
waf_rate_limit = 2000

# ACM certificate ARN (must be in us-east-1 for CloudFront).
# Empty = CloudFront default cert, dev only.
# Production: set to a real ACM ARN to enforce TLSv1.2_2021.
acm_certificate_arn = ""
