terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" { region = var.region }
provider "tls" {}

data "aws_caller_identity" "current" {}

# Thumbprint fetched dynamically — GitHub rotates it periodically
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

locals {
  oidc_arn = aws_iam_openid_connect_provider.github.arn
  aud_key  = "token.actions.githubusercontent.com:aud"
  sub_key  = "token.actions.githubusercontent.com:sub"
}

# ── CI role — pull requests ───────────────────────────────────────────────────
# All CI steps (tf validate -backend=false, docker build, trivy, kubectl dry-run)
# run locally and need zero AWS calls. Role exists for future plan-on-PR usage.

resource "aws_iam_role" "ci" {
  name = "github-actions-ci-${var.project}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { (local.aud_key) = "sts.amazonaws.com" }
        StringLike   = { (local.sub_key) = "repo:${var.github_repo}:pull_request" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci" {
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadOnly"
      Effect   = "Allow"
      Action   = ["ecr:DescribeRepositories", "eks:DescribeCluster", "sts:GetCallerIdentity"]
      Resource = "*"
    }]
  })
}

# ── Deploy role — pushes to main only ────────────────────────────────────────
# StringEquals on sub (not StringLike) — only the exact main branch can assume
# this role; feature branches cannot trigger deploys.

resource "aws_iam_role" "deploy" {
  name = "github-actions-deploy-${var.project}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          (local.aud_key) = "sts.amazonaws.com"
        }
        # environment:dev when job uses `environment: dev`
        # ref:refs/heads/main for direct branch pushes without environment
        StringLike = {
          (local.sub_key) = [
            "repo:${var.github_repo}:environment:dev",
            "repo:${var.github_repo}:ref:refs/heads/main"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy_infra" {
  role = aws_iam_role.deploy.id
  name = "infra-services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PlatformServices"
        Effect = "Allow"
        Action = [
          "ec2:*", "eks:*", "ecr:*",
          "cloudwatch:*", "logs:*",
          "cloudfront:*", "wafv2:*",
          "guardduty:*", "cloudtrail:*",
          "sns:*", "kms:*", "s3:*",
          "dynamodb:*", "ssm:*",
          "autoscaling:Describe*",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      },
      {
        # IAM needed for Terraform to create IRSA roles and EKS service roles.
        # Production hardening: add iam:PermissionsBoundary condition.
        Sid    = "IAMForTerraform"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
          "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:GetRolePolicy", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:UpdateAssumeRolePolicy",
          "iam:CreatePolicy", "iam:DeletePolicy",
          "iam:GetPolicy", "iam:GetPolicyVersion",
          "iam:ListPolicyVersions", "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion", "iam:TagPolicy",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:PassRole",
          "iam:CreateServiceLinkedRole",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile", "iam:ListInstanceProfilesForRole",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid    = "StateBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration"
        ]
        Resource = [
          "arn:aws:s3:::${var.state_bucket_name}",
          "arn:aws:s3:::${var.state_bucket_name}/*"
        ]
      },
      {
        Sid    = "StateLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}"
      }
    ]
  })
}
