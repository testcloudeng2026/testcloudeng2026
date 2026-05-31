# hello-platform

A production-oriented internal API platform built on AWS EKS, delivered via Terraform and GitHub Actions.

---

## Overview

This repository delivers a minimal but production-oriented cloud platform foundation for a stateless internal API service. It demonstrates Infrastructure as Code, security, observability, and CI/CD practices aligned with Amrize's AWS-primary, multi-cloud-bound context.

**What is deployed:**

| Layer | Technology |
|---|---|
| Application | Python (FastAPI) — `GET /` returns JSON, `GET /health` for probes |
| Container | Docker multi-stage image, non-root uid=1000, read-only filesystem |
| Registry | Amazon ECR — image scanning on push, lifecycle policy |
| Compute | Amazon EKS (managed node group, private subnets, IMDSv2, encrypted EBS) |
| Ingress | NGINX Ingress Controller → Network Load Balancer |
| Edge / WAF | CloudFront + AWS WAF v2 (SQLi, XSS, IP reputation, rate limiting) |
| Networking | VPC `/21`, public `/27` subnets (NLB/NAT), private `/24` subnets (pods) |
| IAM | IRSA — least-privilege pod identity; GitHub OIDC for CI/CD |
| Secrets | KMS CMK for EKS secrets (etcd), S3 state, and EBS volumes |
| State | S3 (KMS-encrypted, versioned) + DynamoDB (locking, PITR) |
| Observability | CloudWatch logs + restart alarm, GuardDuty, CloudTrail |
| CI/CD | GitHub Actions — Terraform validate, Trivy (blocking), kubectl dry-run, deploy |

See [docs/architecture.md](docs/architecture.md) for network, application flow, and security boundary diagrams.

---

## Setup Instructions

### Prerequisites

- AWS CLI v2 configured with an account you control
- Terraform >= 1.6
- Docker
- `kubectl` and `helm`
- A GitHub repository with Actions enabled
- _(For live HTTPS with custom domain)_ A Route53 hosted zone

### Step 0 — Bootstrap remote state

The S3 bucket and KMS key backing Terraform state must exist before `terraform init` can run.

```bash
cd terraform/bootstrap
terraform init
terraform apply
# Outputs: bucket_name, kms_key_arn, dynamodb_table
```

Edit `terraform/environments/dev/backend.tf` — replace `<YOUR_ACCOUNT_ID>` and `<KMS_KEY_ARN>` with the bootstrap outputs.

### Step 1 — Configure GitHub OIDC (one-time)

GitHub Actions authenticates to AWS via OIDC — no stored credentials needed.

1. Create an IAM OIDC identity provider:
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`

2. Create two IAM roles trusting the OIDC provider, scoped to your repo:
   - **CI role** (`AWS_CI_ROLE_ARN`): for pull requests (read-only AWS access)
   - **Deploy role** (`AWS_DEPLOY_ROLE_ARN`): for pushes to `main` only

   Minimum permissions for the deploy role: EKS, EC2/VPC, IAM (for IRSA), ECR, CloudWatch, KMS, S3/DynamoDB (state), WAF, CloudFront, GuardDuty, CloudTrail.

3. Add both ARNs as GitHub Actions secrets: `AWS_CI_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`.

### Step 2 — Deploy infrastructure (first apply)

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply
```

Expected resources: ~50 (VPC, subnets, IGW, NAT, EKS cluster, node group, OIDC, ECR, IAM roles, KMS keys, CloudWatch, GuardDuty, CloudTrail, WAF WebACL).

> **Note:** CloudFront is skipped on this first apply — the NLB DNS is not yet known. It is created in Step 3b.

### Step 3 — Install NGINX Ingress Controller

```bash
aws eks update-kubeconfig --name hello-platform-dev --region us-east-1

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb
```

### Step 3b — Attach WAF via CloudFront (second apply)

AWS WAF cannot attach directly to an NLB. CloudFront sits in front of the NLB and WAF inspects every request at the edge before it enters your VPC.

```bash
# Wait for NLB to be provisioned (~2 min), then capture its DNS name
NLB_DNS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "nlb_dns_name = \"$NLB_DNS\"" >> terraform/environments/dev/terraform.tfvars

cd terraform/environments/dev
terraform apply   # creates CloudFront distribution + WAF association (~5 min)

terraform output cloudfront_domain   # your public HTTPS endpoint
```

Traffic flow:
```
Internet → CloudFront (WAF) → NLB → NGINX Ingress → hello-platform pod
```

### Step 4 — Deploy the application

```bash
ECR_URL=$(terraform -chdir=terraform/environments/dev output -raw ecr_repository_url)
APP_ROLE=$(terraform -chdir=terraform/environments/dev output -raw app_role_arn)

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$ECR_URL"
docker build -t "$ECR_URL:1.0.0" app/
docker push "$ECR_URL:1.0.0"

sed -i "s|<ECR_REPOSITORY_URL>|${ECR_URL}|g" k8s/deployment.yaml
sed -i "s|<IMAGE_TAG>|1.0.0|g"               k8s/deployment.yaml
sed -i "s|<APP_ROLE_ARN>|${APP_ROLE}|g"      k8s/serviceaccount.yaml

kubectl apply -f k8s/
kubectl rollout status deployment/hello-platform -n hello-platform
```

### Step 5 — Verify

```bash
CF_DOMAIN=$(terraform -chdir=terraform/environments/dev output -raw cloudfront_domain)
curl https://$CF_DOMAIN/
curl https://$CF_DOMAIN/health
```

Expected response from `/`:
```json
{ "application": "hello-platform", "environment": "dev", "version": "1.0.0" }
```

### Cleanup

```bash
kubectl delete -f k8s/
terraform -chdir=terraform/environments/dev destroy
# Bootstrap bucket has prevent_destroy = true; remove the flag then run destroy manually
```

---

## Design Decisions

### Cloud provider — AWS

Amrize is AWS-primary. Starting on EKS gives immediate value on familiar ground while keeping the door open for GCP — see the Kubernetes decision below.

### Compute — EKS over ECS/Fargate, App Runner, or EC2

ECS is an AWS-proprietary control plane. The same task definition cannot run on GCP without a rewrite. Kubernetes is the one abstraction that works identically on EKS and GKE:

| Concern | ECS/Fargate | App Runner | EC2 | **EKS** |
|---|---|---|---|---|
| Multi-cloud portability | None | None | None | **Full — same manifests on GKE** |
| Pod identity | Task role (AWS only) | None | Instance profile | **IRSA → GKE Workload Identity** |
| Ingress | ALB (AWS only) | Managed (no control) | Manual | **NGINX (cloud-agnostic)** |
| Operational surface | Low | Minimal | High | Medium |
| Dev cost (approx.) | ~$50/month | ~$20/month | Variable | **~$150/month** |

**Tradeoff accepted:** EKS has higher cost (~$73/month control plane) and more operational surface than ECS or App Runner. The premium is justified because: (a) the platform will host multiple services, diluting the fixed control-plane cost; (b) the company is migrating to GCP — Kubernetes manifests, NGINX Ingress, and IRSA port directly to GKE/Workload Identity without rewrite.

### Ingress — NGINX over AWS Load Balancer Controller

AWS Load Balancer Controller uses AWS-specific Ingress annotations that do not exist on GKE. NGINX Ingress defines behaviour in standard `networking.k8s.io/v1` Ingress resources — the same YAML deploys on GKE without change. For the same reason, WAF is attached via CloudFront (edge) rather than an ALB-specific integration.

### WAF + CloudFront

AWS WAF v2 cannot attach to a Network Load Balancer — only ALB, CloudFront, API Gateway, and AppSync are supported. CloudFront sits in front of the NLB and provides:

- **WAF inspection at the edge** — malicious traffic is blocked before it enters the VPC
- **AWS Shield Standard** (free) — absorbs volumetric DDoS
- **TLS termination at the edge** — `TLSv1.2_2021` minimum

WAF rule set (evaluated in priority order):

| Priority | Rule | Threat |
|---|---|---|
| 1 | AWSManagedRulesCommonRuleSet | SQLi, XSS, OWASP Top 10 |
| 2 | AWSManagedRulesKnownBadInputsRuleSet | Log4Shell, SSRF probes |
| 3 | AWSManagedRulesAmazonIpReputationList | Botnets, threat-actor IPs |
| 4 | Rate limit 2,000 req / 5 min per IP | Brute force, credential stuffing |

### Identity and secrets — IRSA, no hardcoded credentials

- **IRSA** (IAM Roles for Service Accounts): each pod gets a distinct IAM identity scoped to its Kubernetes service account. Instance profiles would grant all pods on a node the same permissions — IRSA prevents lateral movement between workloads.
- **GitHub OIDC**: CI/CD assumes an IAM role via web identity federation. No IAM access keys are stored as GitHub secrets.
- **Secret tiering**: non-sensitive config → ConfigMap; low-sensitivity params → SSM Parameter Store (read via IRSA); credentials → SSM SecureString / Secrets Manager (IRSA path `/hello-platform/*` is pre-scoped).
- **KMS CMK** with annual auto-rotation encrypts: EKS etcd secrets, EBS node volumes, S3 state bucket. AWS managed keys are not used for any of these — customer-managed keys are required for auditability and revocation control.

### VPC sizing — /21

A `/16` wastes 65,534 IPs and would be rejected by enterprise IPAM. A `/24` is too small for EKS — AWS VPC CNI assigns a real VPC IP per pod, and splitting a /24 into four subnets leaves private subnets with ~59 usable IPs, exhausted by 5 busy nodes.

| VPC mask | Total IPs | Private subnet | Pod capacity per AZ | Verdict |
|---|---|---|---|---|
| `/24` | 256 | `/26` (59 usable) | ~50 pods | Too small for EKS |
| `/22` | 1,024 | `/24` (251 usable) | ~240 pods | Acceptable, tight |
| **`/21`** | **2,048** | **`/24` (251 usable)** | **~240 pods + reserve** | **Recommended** |
| `/20` | 4,096 | `/23` (507 usable) | ~500 pods | Wasteful in IPAM |

Public subnets are `/27` (32 IPs) — sufficient for NAT Gateway and NLB. `10.0.6.0/23` is intentionally unallocated as reserve for future platform services within the same VPC.

### Single NAT Gateway (dev)

One NAT Gateway costs ~$45/month and creates an AZ dependency for outbound traffic. Production requires one per AZ for HA. This is a two-line change in the `networking` module (`aws_nat_gateway` + per-AZ EIP using `count`). Documented as a deliberate dev cost tradeoff.

### Terraform state

S3 bucket with KMS CMK encryption, versioning, and all public access blocked. DynamoDB with pay-per-request billing and point-in-time recovery provides atomic locking. Bootstrap config is isolated (separate `terraform init`) to avoid the chicken-and-egg ordering problem.

### Cost awareness

| Resource | Approx. monthly (dev) | Notes |
|---|---|---|
| EKS control plane | $73 | Fixed; amortized across multiple services in prod |
| EC2 nodes (1× t3.small) | $15 | Scale to 2+ for prod HA |
| NAT Gateway | $45 | Single AZ; prod needs 2× |
| CloudFront | ~$1–5 | Pay per request; negligible for internal API |
| KMS keys (3×) | $3 | $1/key/month |
| GuardDuty | ~$4 | Based on log volume |
| CloudTrail | ~$2 | First trail free per region |
| ECR | <$1 | Lifecycle policy limits storage |
| **Estimated total** | **~$145–155/month** | |

ECS/Fargate alternative would cost ~$50/month. The $100 premium buys multi-cloud portability and a shared Kubernetes platform that can host additional services without adding another control plane.

### Reusable platform capabilities

These modules are designed to be consumed across the organisation without modification:

| Module | What it standardises |
|---|---|
| `modules/networking` | VPC sizing, subnet tags for K8s LB discovery, NAT strategy |
| `modules/eks` | Cluster version pinning, IMDSv2, OIDC, encrypted EBS |
| `modules/iam` | IRSA trust policy template — each team gets a scoped role |
| `modules/kms` | CMK with auto-rotation — one call per key purpose |
| `modules/waf` | WAF WebACL with managed rule sets + rate limit |
| `modules/cloudfront` | Edge distribution wired to WAF — reusable for any NLB origin |
| `modules/observability` | Log retention, restart alarm, GuardDuty, CloudTrail |

---

## Limitations & Future Improvements

### Deliberate omissions

| Item | Reason |
|---|---|
| Live deployment | Not required; `terraform validate/plan` is the stated bar |
| ACM certificate + custom domain | Requires a real Route53 hosted zone; documented as prerequisite |
| HPA (Horizontal Pod Autoscaler) | `replicas: 2` provides basic HA; HPA is the obvious next step |
| Multi-AZ NAT Gateway | Dev cost tradeoff (~$45/month × 2); one-line change for prod |
| Multi-environment promotion pipeline | Pattern established in `environments/`; staging/prod replicate the same structure |
| OPA/Gatekeeper policy enforcement | Image registry allowlist, non-root enforcement — appropriate for prod |
| Secrets Manager full integration | SSM Parameter Store is sufficient for this app; Secrets Manager path is pre-scoped via IRSA |

### With more time

- **cert-manager** — automatic TLS certificate provisioning via ACM or Let's Encrypt, eliminating the manual domain prerequisite
- **External DNS** — automatic Route53 record management from Ingress resources
- **HPA + KEDA** — scale on request rate or queue depth, not just CPU
- **Karpenter** — replace managed node groups for better bin-packing and spot instance support, reducing node cost ~60%
- **Renovate Bot** — automated PRs for Terraform module updates, Docker base image bumps, and Kubernetes version upgrades
- **AWS Config rules** — continuous compliance monitoring (encrypted volumes, public access blocks, MFA delete on S3)
- **Multi-AZ NAT Gateway** — one gateway per AZ eliminates the outbound single point of failure

---

## Reliability & Operations Analysis

### Scaling strategy

**Current:** 2 replicas (PodDisruptionBudget guarantees `minAvailable: 1` during node drains), single `t3.small` node.

**Production path:**
1. HPA on CPU (target 60%) or request rate via KEDA
2. Node group autoscaling: `min=2, max=6` across 2 AZs — eliminates single-node SPOF
3. Long-term: Karpenter for bin-packing and spot instance support

### Deployment and rollback

Kubernetes rolling update (default): new pod must pass readiness probe on `/health` before the old one is terminated. CI/CD tags images with `github.sha` — `latest` is never used in production.

**Zero-downtime sequence:**
1. CI pushes image `ECR_URL:sha` to ECR
2. `kubectl apply` updates the Deployment image reference
3. Kubernetes starts new pod, waits for readiness
4. Old pod terminates only after new pod is healthy and serving traffic

**Rollback:**
```bash
kubectl rollout undo deployment/hello-platform -n hello-platform
# or to a specific revision:
kubectl rollout history deployment/hello-platform -n hello-platform
kubectl rollout undo deployment/hello-platform --to-revision=<N> -n hello-platform
```

Infrastructure rollback: Terraform state is versioned in S3; `terraform apply` from a previous commit restores prior state.

### Key failure scenarios

| Scenario | Detection | Response |
|---|---|---|
| Pod crash loop | CloudWatch alarm (container restarts > 0) | `kubectl rollout undo`; investigate with `kubectl logs` |
| Bad deploy | Readiness probe blocks traffic; rolling update stalls | Rollback with `kubectl rollout undo` |
| Node failure | EKS auto-replaces; 2 replicas across nodes prevents downtime | PDB ensures 1 pod stays Running during voluntary drains |
| NAT Gateway failure | Pods lose outbound (ECR pulls, SSM, CloudWatch) | In prod: one NAT per AZ eliminates this SPOF |
| WAF false positive | Legitimate request blocked (WAF 403) | Review WAF sampled requests; switch rule to Count mode |
| State lock stuck | `terraform apply` hangs indefinitely | `terraform force-unlock <LOCK_ID>` after confirming no concurrent apply |
