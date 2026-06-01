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

# WAF — REGIONAL scope, attaches directly to the ALB created by AWS LBC.
module "waf" {
  source = "../../modules/waf"

  name       = "${local.name}-waf"
  scope      = "REGIONAL"
  rate_limit = var.waf_rate_limit
  tags       = local.tags
}

# IAM role for AWS Load Balancer Controller (IRSA).
module "iam_lbc" {
  source = "../../modules/iam-lbc"

  cluster_name      = local.name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.tags
}

# Self-signed ACM certificate for ALB HTTPS listener (managed by Terraform).
module "acm" {
  source      = "../../modules/acm"
  common_name = "hello-platform-${var.environment}.internal"
  tags        = local.tags
}
