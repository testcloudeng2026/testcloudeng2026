# hello-platform

A production-grade internal API platform on AWS EKS, delivered entirely via Terraform and GitHub Actions — no manual clicks, no stored credentials.

---

## Live Status

| Environment | Account | Endpoint | WAF |
|---|---|---|---|
| **dev** | `196209078497` | `https://k8s-hellopla-hellopla-839d47d95a-424177946.us-east-1.elb.amazonaws.com` ⚠️ self-signed | WAF Regional attached to ALB |
| **prod** | `590423939674` | `https://k8s-hellopla-hellopla-d69416d173-1696995132.us-east-1.elb.amazonaws.com` ⚠️ self-signed | WAF Regional attached to ALB |

> **Note on CloudFront:** The original design used CloudFront + WAF (CLOUDFRONT scope) as the public edge.
> New AWS accounts require manual verification by AWS Support before CloudFront resources can be created —
> a process that can take several hours. To deliver a working WAF-protected endpoint without that delay,
> the architecture was updated to use an **Application Load Balancer with WAF Regional scope** attached directly.
> This provides equivalent HTTP-layer protection (SQLi, XSS, IP reputation, rate limiting) without the
> CloudFront dependency. CloudFront can be re-introduced as an optional CDN/caching layer in the future.

---

## What is deployed

| Layer | Technology |
|---|---|
| Application | Python (FastAPI) — `GET /` returns JSON, `GET /health` for probes |
| Container | Docker multi-stage image, non-root uid=1000, read-only filesystem |
| Registry | Amazon ECR — image scanning on push, lifecycle policy |
| Compute | Amazon EKS (managed node group, private subnets, IMDSv2, encrypted EBS) |
| Ingress | AWS Load Balancer Controller → Application Load Balancer |
| Edge / WAF | ALB + AWS WAF v2 Regional (SQLi, XSS, IP reputation, rate limiting) |
| Networking | VPC `/21`, public `/27` subnets (ALB/NAT), private `/24` subnets (pods) |
| IAM | IRSA — least-privilege pod identity; GitHub OIDC for CI/CD (no stored credentials) |
| Secrets | KMS CMK for EKS secrets (etcd), S3 state, and EBS volumes |
| State | S3 (KMS-encrypted, versioned) + DynamoDB (locking) — centralized in management account |
| Observability | CloudWatch logs + restart alarm, GuardDuty, CloudTrail |
| Accounts | AWS Organizations — management + dev + prod member accounts |

---

## AWS Account Structure

```
AWS Organizations (management: 977145922427)
├── Terraform state bucket: hello-platform-tfstate-977145922427
├── DynamoDB lock table:    hello-platform-tfstate-lock
├── KMS CMK:               arn:aws:kms:us-east-1:977145922427:key/e91d26d8-...
│
├── OU: dev
│   └── Account: hello-platform-dev (196209078497)
│       ├── EKS cluster:   hello-platform-dev
│       ├── ECR:           196209078497.dkr.ecr.us-east-1.amazonaws.com/hello-platform
│       └── State key:     dev/terraform.tfstate
│
└── OU: prod
    └── Account: hello-platform-prod (590423939674)
        ├── EKS cluster:   hello-platform-prod
        ├── ECR:           590423939674.dkr.ecr.us-east-1.amazonaws.com/hello-platform
        └── State key:     prod/terraform.tfstate
```

Both member accounts access the centralized state bucket via cross-account S3 + KMS policies.

---

## Branching Strategy

```
feature/* ──→ develop ──────────────────────────→ main
                │                                    │
                ▼                                    ▼
         Auto-deploy to dev              Manual approval → deploy to prod
         (account 196209078497)          (account 590423939674)
```

| Branch | Protection | Deploys to |
|---|---|---|
| `feature/*` | None | — |
| `develop` | 1 reviewer + CI required | dev account (auto) |
| `main` | 1 reviewer + CI required + dismiss stale | prod account (after approval gate) |

Push directly to `main` or `develop` is **blocked** — all changes go through pull requests.

---

## CI/CD Pipelines

### On every Pull Request (`ci.yml`)

Triggered on PRs to `main` or `develop`. Runs without a deploy.

| Job | What it does |
|---|---|
| **Terraform Plan** | Runs `terraform plan` against real dev state — posts diff as PR comment |
| **Docker Build & Scan** | Builds image, runs Trivy (blocks on HIGH/CRITICAL CVEs) |
| **K8s Dry-run** | `kubectl apply --dry-run=client` validates all manifests |

All three checks must pass before a PR can be merged.

### On merge to `develop` (`deploy.yml` — Deploy to Dev)

Full deploy to account `196209078497`:

1. `terraform apply` — creates/updates VPC, EKS, ECR, IAM, observability, WAF Regional, LBC IAM role
2. Docker build + Trivy scan (blocking)
3. Push image to ECR tagged with `github.sha`
4. Install AWS Load Balancer Controller via Helm (idempotent)
5. `kubectl apply` — deploys to EKS with rolling update (`maxUnavailable=1, maxSurge=0`)
6. Open NodePort range in node SG + register node in ALB target group + wire forwarding rule
7. Setup HTTPS listener (self-signed cert via ACM) + HTTP→HTTPS redirect (idempotent)
8. Wait for target healthy (up to 3 min)
9. Prints live HTTPS endpoint

### On merge to `main` (`deploy.yml` — Deploy to Prod)

Same pipeline targeting account `590423939674`. Requires manual approval in the `prod` GitHub environment before execution.

### Manual workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `accounts.yml` | `workflow_dispatch` (plan/apply) | Create/update AWS Organizations accounts |
| `destroy.yml` | `workflow_dispatch` (requires typing `DESTROY`) | Destroy an environment's infrastructure |

---

## IAM & Security

### GitHub Actions roles (no stored credentials)

| Role | Account | Trust | Used by |
|---|---|---|---|
| `github-actions-ci-hello-platform` | `977145922427` | `pull_request` | CI plan job |
| `github-actions-deploy-hello-platform` | `977145922427` | `environment:management` | accounts.yml, destroy.yml |
| `github-actions-deploy-hello-platform` | `196209078497` | `environment:dev` | deploy-dev job |
| `github-actions-deploy-hello-platform` | `590423939674` | `environment:prod` | deploy-prod job |

All roles use GitHub OIDC — zero IAM access keys stored anywhere.

### Security controls

| Control | Implementation |
|---|---|
| No credentials in CI | GitHub OIDC, trust policy scoped to exact repo + environment |
| Pod identity | IRSA — pod assumes IAM role directly, no shared node credentials |
| SSRF → credential theft | IMDSv2 required on all nodes |
| Secrets at rest | KMS CMK encrypts EKS etcd, EBS volumes, S3 state |
| Container hardening | uid=1000, `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL caps |
| Network isolation | NetworkPolicy default-deny-all + explicit allowlist |
| Image scanning | Trivy HIGH/CRITICAL blocking before ECR push + ECR scan on push |
| DDoS / rate limit | WAF WebACL 2000 req/5min per IP (via ALB) |
| Threat detection | GuardDuty: S3, K8s audit logs, EBS malware protection |
| Audit trail | CloudTrail management + data events |
| State integrity | S3 versioned + DynamoDB lock + public access block |

---

## Repository Structure

```
.
├── app/
│   ├── main.py              # FastAPI: GET / + GET /health
│   ├── requirements.txt
│   └── Dockerfile           # multi-stage, non-root uid=1000
├── k8s/
│   ├── namespace.yaml
│   ├── deployment.yaml      # replicas:2, maxUnavailable:1, maxSurge:0
│   ├── service.yaml         # NodePort port 8080
│   ├── ingress.yaml         # ALB Ingress (AWS LBC) + WAF ARN annotation
│   ├── configmap.yaml
│   ├── serviceaccount.yaml  # IRSA annotation
│   ├── networkpolicy.yaml   # default-deny + allow ALB VPC CIDR + DNS/443 egress
│   ├── poddisruptionbudget.yaml
│   └── resourcequota.yaml
├── terraform/
│   ├── bootstrap/           # One-time: S3 + DynamoDB + KMS for state
│   ├── github-oidc/         # One-time: OIDC provider + CI/deploy roles
│   ├── management/          # AWS Organizations: accounts + OUs
│   ├── modules/
│   │   ├── networking/      # VPC, subnets, IGW, NAT GW, Flow Logs
│   │   ├── ecr/             # ECR repo + lifecycle policy
│   │   ├── eks/             # Cluster, node group, OIDC, IMDSv2, CW addon
│   │   ├── iam/             # IRSA role for the app pod
│   │   ├── kms/             # CMK with auto-rotation
│   │   ├── observability/   # CloudWatch, GuardDuty, CloudTrail, SNS
│   │   ├── waf/             # WAF WebACL scope REGIONAL (attached to ALB)
│   │   ├── iam-lbc/         # IRSA role for AWS Load Balancer Controller
│   │   └── cloudfront/      # CloudFront module (available, not currently deployed)
│   └── environments/
│       ├── dev/             # Deploys to account 196209078497
│       └── prod/            # Deploys to account 590423939674
└── .github/workflows/
    ├── ci.yml               # PR: tf plan comment, trivy, kubectl dry-run
    ├── deploy.yml           # push develop→dev, push main→prod
    ├── accounts.yml         # manual: create/update AWS accounts
    └── destroy.yml          # manual: terraform destroy (requires DESTROY confirmation)
```

---

## Setup Instructions

### Prerequisites

- AWS account with admin access (to run the one-time bootstrap)
- AWS CLI v2 configured (`aws configure`)
- Git + GitHub CLI (`gh auth login`)
- A GitHub repository with Actions enabled

### Step 0 — Bootstrap remote state (one-time, run locally)

Creates the S3 bucket, DynamoDB lock table, and KMS key that back all Terraform state. This is the documented chicken-and-egg step — it must exist before `terraform init` can run.

```bash
cd terraform/bootstrap
terraform init
terraform apply
# Outputs: bucket_name, kms_key_arn, dynamodb_table
```

### Step 1 — Create GitHub OIDC roles (one-time, run locally)

Creates the IAM OIDC provider and the CI/deploy roles that GitHub Actions assumes. No IAM keys are stored.

```bash
cd terraform/github-oidc
terraform init
terraform apply
# Outputs: ci_role_arn, deploy_role_arn
```

Add these two ARNs as GitHub Actions secrets:
- `AWS_CI_ROLE_ARN` → repo-level secret
- `AWS_DEPLOY_ROLE_ARN` → per environment (`dev`, `prod`, `management`)

### Step 2 — Create AWS Organizations accounts (one-time, via pipeline)

Trigger the `accounts.yml` workflow manually from GitHub Actions → **Run workflow** → action: `apply`. This creates the `dev` and `prod` member accounts inside your AWS Organization.

### Step 3 — Deploy

All subsequent deployments are fully automated via GitHub Actions:

| Action | Result |
|---|---|
| Push to `develop` | Auto-deploys to dev account |
| PR `develop → main` + approval | Deploys to prod account after gate |

### Cleanup

```bash
# 1. Destroy environment infrastructure (triggers terraform destroy)
# Go to GitHub Actions → destroy.yml → Run workflow → type DESTROY

# 2. Destroy Organizations accounts (manual in AWS Console — irreversible)

# 3. Destroy bootstrap state bucket (remove prevent_destroy first)
cd terraform/bootstrap
terraform destroy
```

---

## Onboarding a New Developer

### Prerequisites

- AWS CLI v2
- Git + GitHub CLI (`gh`)
- Access to the `testcloudeng2026` GitHub org

### Setup

```bash
# 1. Clone
git clone https://github.com/testcloudeng2026/testcloudeng2026
cd testcloudeng2026

# 2. Create your feature branch
git checkout develop
git checkout -b feature/my-change

# 3. Make changes, push, open PR to develop
git push origin feature/my-change
gh pr create --base develop --title "feat: my change"
```

The CI pipeline runs automatically on the PR. Once approved and merged, the deploy pipeline runs automatically to the dev account.

### To promote to production

Open a PR from `develop` to `main`. Requires 1 reviewer. After merge, a manual approval gate in the `prod` GitHub environment must be clicked before the deploy runs.

---

## Design Decisions

### AWS Organizations (multi-account)

Separate AWS accounts provide blast-radius isolation that resource naming cannot:

| Concern | Single account | Multi-account |
|---|---|---|
| `terraform destroy` blast radius | Destroys prod if wrong env | Impossible by design |
| IAM boundaries | Soft (naming convention) | Hard (account boundary) |
| Billing / cost attribution | Mixed | Per-account Cost Explorer |
| Compliance (SCPs) | Same policies for all | Stricter SCPs on prod OU |

Management account (`977145922427`) holds only Terraform state, OIDC providers, and Organizations management. No workloads run there.

### Compute — EKS over ECS/Fargate

Amrize is migrating to GCP. Kubernetes Deployments, Services, and IRSA map 1:1 to GKE/Workload Identity. ECS task definitions do not.

| Concern | ECS/Fargate | **EKS** |
|---|---|---|
| Multi-cloud portability | None | **Full — same manifests on GKE** |
| Pod identity | Task role (AWS only) | **IRSA → GKE Workload Identity** |
| Ingress | ALB (AWS only) | **ALB (AWS) / GKE Ingress (GCP)** |
| Approx. cost | ~$50/month | ~$150/month |

The $100/month premium buys a portable platform that migrates to GKE without pod-level manifest rewrites.

### Ingress — AWS Load Balancer Controller + WAF Regional

AWS LBC creates an ALB directly from the Kubernetes Ingress resource. WAF v2 is attached directly to the ALB via the `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation, providing HTTP-layer protection (SQLi, XSS, IP reputation, rate limiting) without requiring CloudFront.

### WAF via ALB (not CloudFront)

AWS WAF v2 Regional scope attaches directly to an ALB, providing protection at the load balancer layer before traffic reaches the pods. The `cloudfront/` Terraform module is available in the repo for future use if a CDN layer is needed.

WAF rule set:

| Priority | Rule | Threat blocked |
|---|---|---|
| 1 | AWSManagedRulesCommonRuleSet | SQLi, XSS, OWASP Top 10 |
| 2 | AWSManagedRulesKnownBadInputsRuleSet | Log4Shell, SSRF |
| 3 | AWSManagedRulesAmazonIpReputationList | Botnets, threat-actor IPs |
| 4 | Rate limit 2,000 req / 5 min per IP | Brute force, credential stuffing |

### Terraform state — centralized in management account

State lives in the management account S3 bucket with cross-account bucket + KMS policies allowing only the deploy roles of each member account. This avoids bootstrapping a new S3 bucket per account while keeping state isolated per environment (`dev/terraform.tfstate`, `prod/terraform.tfstate`).

### Rolling update strategy — `maxUnavailable=1, maxSurge=0`

Default Kubernetes rolling update (`maxSurge=1`) would require capacity for 3 pods simultaneously on a single `t3.small` node. Setting `maxSurge=0` means one old pod is terminated before a new one starts — fitting within the node's capacity. Production should use multi-node groups where the default surge strategy works.

---

## Observability

| Signal | Implementation |
|---|---|
| Pod logs | `amazon-cloudwatch-observability` addon (Fluent Bit) → `/aws/containerinsights/hello-platform-dev/application` |
| Metrics | CloudWatch Container Insights |
| Alarm | `pod_number_of_container_restarts > 0` for 2 periods → SNS |
| GuardDuty | S3, K8s audit logs, EBS malware protection |
| Control plane logs | api, audit, authenticator, controllerManager, scheduler → CloudWatch |
| VPC Flow Logs | Enabled with dedicated IAM role and log group |
| Audit trail | CloudTrail management + data events |

---

## Reliability & Operations

### Scaling Strategy

**Current (dev):** 2 replicas on a single `t3.small` node. The PodDisruptionBudget (`minAvailable: 1`) ensures at least one pod survives voluntary drains.

**Production path:**
1. **Horizontal Pod Autoscaler** on CPU target 60% — scales pods without node changes
2. **Node group autoscaling** `min=2, max=6` across 2 AZs — eliminates single-node SPOF
3. **Karpenter** (long-term) — bin-packing + spot instance support reduces node cost ~60%

The application is stateless by design: no session state, no local disk writes. Any replica can serve any request, so horizontal scaling is trivially safe.

### Deployment and Rollback

**Deploy flow (zero-downtime rolling update):**
1. CI pushes image `ECR_URL:github.sha` — `latest` tag is never used in production
2. `kubectl apply` triggers a rolling update: `maxUnavailable=1, maxSurge=0`
3. Kubernetes starts the new pod and waits for the readiness probe (`GET /health → 200`)
4. Old pod terminates only after the new pod is confirmed healthy and serving traffic
5. If the readiness probe never passes, the rollout stalls and the old pod keeps serving

**Application rollback:**
```bash
# Instant rollback to the previous revision
kubectl rollout undo deployment/hello-platform -n hello-platform

# Rollback to a specific revision
kubectl rollout history deployment/hello-platform -n hello-platform
kubectl rollout undo deployment/hello-platform --to-revision=<N> -n hello-platform
```

**Infrastructure rollback:**
Terraform state is versioned in S3. Rolling back infrastructure means reverting the commit and running the deploy pipeline — `terraform apply` converges to the previous state.

**Image rollback:**
Every image is tagged with `github.sha` and retained in ECR (lifecycle policy keeps last 10 images). Re-deploying a previous commit re-pushes the corresponding image tag.

### Key Failure Scenarios

| Scenario | Detection | Response |
|---|---|---|
| Pod crash loop | CloudWatch alarm (`restarts > 0` × 2 periods) → SNS | `kubectl rollout undo`; investigate with `kubectl logs` |
| Bad deploy — readiness probe fails | Rolling update stalls; old pods keep serving | `kubectl rollout undo` |
| Node failure | EKS replaces node automatically; PDB ensures 1 pod stays Running | Multi-node group in prod eliminates this SPOF |
| NAT Gateway failure | Pods lose outbound (ECR pulls, SSM, CloudWatch) | In prod: one NAT per AZ eliminates this SPOF |
| WAF false positive | Legitimate request blocked (HTTP 403) | Review WAF sampled requests in CloudWatch; switch rule to Count mode temporarily |
| Terraform state lock stuck | `terraform apply` hangs indefinitely | `terraform force-unlock <LOCK_ID>` after confirming no concurrent apply |
| ALB target unhealthy | App unreachable; ALB returns 502 | Check pod readiness with `kubectl get pods -n hello-platform`; redeploy if needed |

---

## Known Limitations & Next Steps

| Item | Status | Notes |
|---|---|---|
| HTTPS certificate | Self-signed (active) | Browser shows warning. Replace with ACM + custom domain for production-grade TLS |
| Custom domain | Not implemented | Requires Route53 hosted zone; once added, ACM issues a trusted cert automatically |
| HPA | Not implemented | `replicas: 2` provides basic HA; HPA is the obvious next step |
| Multi-AZ NAT Gateway | Dev uses single NAT (~$45/month) | Two-line change for prod HA |
| Karpenter | Not implemented | Replaces managed node groups for better bin-packing and spot support |
| External DNS | Not implemented | Automates Route53 records from Ingress resources |
| LBC auto-registration | Manual step in pipeline | Node registration is scripted; long-term fix is tagging the node SG with `elbv2.k8s.aws/cluster` |

---

## Cost Estimate

| Resource | Dev (monthly) | Prod (monthly) |
|---|---|---|
| EKS control plane | $73 | $73 |
| EC2 nodes (t3.small × 1 / t3.medium × 2) | $15 | $60 |
| NAT Gateway | $45 | $90 (one per AZ) |
| ALB | ~$8 | ~$8 |
| KMS keys | $3 | $3 |
| GuardDuty | ~$4 | ~$4 |
| CloudTrail | ~$2 | ~$2 |
| ECR + S3 | <$2 | <$2 |
| **Total** | **~$152/month** | **~$242/month** |

AWS Organizations itself is free.
