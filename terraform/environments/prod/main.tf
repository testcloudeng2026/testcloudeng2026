locals {
  name = "${var.app_name}-${var.environment}"

  tags = {
    Project     = var.app_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "kms_eks" {
  source = "../../modules/kms"

  name        = "${local.name}-eks"
  description = "Envelope-encrypts Kubernetes secrets at rest in etcd"
  tags        = local.tags
}

module "networking" {
  source = "../../modules/networking"

  name = local.name

  # /21 VPC — enterprise-appropriate allocation (2,048 IPs).
  # Public /27s are enough for NAT GW + NLB. Private /24s hold pods (AWS VPC CNI).
  # 10.0.6.0/23 is intentionally left unallocated for future platform services.
  vpc_cidr             = "10.0.0.0/21"
  public_subnet_cidrs  = ["10.0.0.0/27", "10.0.0.32/27"]
  private_subnet_cidrs = ["10.0.2.0/24", "10.0.4.0/24"]
  azs                  = ["us-east-1a", "us-east-1b"]

  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  name = var.app_name
  tags = local.tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  vpc_id             = module.networking.vpc_id
  public_subnet_ids  = module.networking.public_subnet_ids
  private_subnet_ids = module.networking.private_subnet_ids
  node_instance_type = var.node_instance_type
  kms_key_arn        = module.kms_eks.key_arn
  tags               = local.tags
}

module "iam" {
  source = "../../modules/iam"

  name              = local.name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.tags
}

module "observability" {
  source = "../../modules/observability"

  name        = local.name
  alarm_email = var.alarm_email
  tags        = local.tags
}

# WAF WebACL is created on first apply (no NLB needed yet).
# CloudFront is created on second apply, after NGINX has provisioned the NLB.
module "waf" {
  source = "../../modules/waf"

  name       = "${local.name}-waf"
  rate_limit = var.waf_rate_limit
  tags       = local.tags
}

module "cloudfront" {
  # Skipped until nlb_dns_name is set in terraform.tfvars after NGINX deploys.
  count  = var.nlb_dns_name != "" ? 1 : 0
  source = "../../modules/cloudfront"

  name                = local.name
  origin_dns_name     = var.nlb_dns_name
  web_acl_arn         = module.waf.web_acl_arn
  acm_certificate_arn = var.acm_certificate_arn
  tags                = local.tags
}
