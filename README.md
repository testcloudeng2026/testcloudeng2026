# hello-platform

A production-grade internal API platform on AWS EKS, delivered entirely via Terraform and GitHub Actions — no manual clicks, no stored credentials.

---

## Live Status

| Environment | Account | Endpoint | WAF |
|---|---|---|---|
| **dev** | `196209078497` | `https://k8s-hellopla-hellopla-839d47d95a-805922077.us-east-1.elb.amazonaws.com` ⚠️ | WAF Regional ✅ |
| **prod** | `590423939674` | `https://k8s-hellopla-hellopla-d69416d173-1696995132.us-east-1.elb.amazonaws.com` ⚠️ | WAF Regional ✅ |

> ⚠️ Self-signed certificate — browser will show a security warning. Click "Advanced → Proceed" to continue. Replace with ACM + custom domain for trusted TLS.

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

1. `terraform apply` — creates/updates VPC, EKS, ECR, IAM, observability, WAF Regional, LBC IAM role, ACM self-signed cert
2. Docker build + Trivy scan (blocking — HIGH/CRITICAL CVEs fail the pipeline)
3. Push image to ECR tagged with `github.sha` (never `latest`)
4. Install AWS Load Balancer Controller via Helm (idempotent `helm upgrade --install`)
5. `kubectl apply` — deploys to EKS with rolling update (`maxUnavailable=1, maxSurge=0`)
6. LBC reconciles the Ingress → provisions ALB with WAF Regional attached, HTTPS listener with ACM cert, HTTP→HTTPS redirect
7. Wait for ALB hostname (up to 5 min) + HTTPS health check (up to 4 min)
8. Prints live HTTPS endpoint

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

### Terraform Architecture

The core deliverable is the Terraform structure, not the application. The design follows three principles: **single-responsibility modules**, **composable environments**, and **centralized state governance**.

#### Module composition pattern

```
terraform/
├── bootstrap/          # Run once — creates the S3 + DynamoDB + KMS that back all state.
│                       # Chicken-and-egg: must exist before terraform init can run anywhere.
├── github-oidc/        # Run once — OIDC provider + IAM roles for GitHub Actions.
│                       # Zero stored IAM keys. All CI/CD authenticates via OIDC federation.
├── management/         # AWS Organizations — account + OU structure.
│                       # Separate from workload Terraform so org changes never touch app state.
├── modules/            # Reusable building blocks. Platform team owns these.
│   ├── networking/     # VPC /21, subnets, IGW, NAT GW, route tables, VPC Flow Logs.
│   ├── eks/            # EKS cluster + managed node group. Bakes in: IMDSv2 enforcement,
│   │                   # KMS etcd encryption, OIDC provider, CloudWatch observability addon.
│   ├── iam/            # IRSA role for the application pod. Trust policy scoped to the
│   │                   # exact cluster OIDC issuer + namespace + service account name.
│   ├── iam-lbc/        # IRSA role for AWS Load Balancer Controller. Separate from app IAM
│   │                   # so the controller's AWS permissions don't bleed into the app role.
│   ├── ecr/            # ECR repository with scan-on-push and lifecycle policy (last 10 images).
│   ├── kms/            # KMS CMK with auto-rotation. Used for EKS etcd, EBS volumes, S3 state.
│   ├── waf/            # WAF WebACL (REGIONAL scope). Attached to ALB via LBC annotation.
│   ├── observability/  # CloudWatch log groups + SNS alarm + GuardDuty + CloudTrail.
│   ├── acm/            # Self-signed ACM certificate (dev). Swap for DNS-validated in prod.
│   └── cloudfront/     # CloudFront module — available but not currently deployed (see note).
└── environments/       # Product team config. One folder per environment.
    ├── dev/            # Deploys to account 196209078497. backend.tf → dev/terraform.tfstate.
    └── prod/           # Deploys to account 590423939674. backend.tf → prod/terraform.tfstate.
```

Each `environments/<env>/main.tf` is purely compositional — it calls modules and wires their outputs together. No resource definitions live there. This enforces a clean contract: the platform team evolves modules; product teams evolve environment config.

#### State architecture

State lives in a **single S3 bucket in the management account** (`977145922427`). Both member accounts access it via cross-account S3 bucket policy and KMS key policy. This avoids creating a new state bucket per account (operational overhead) while keeping state isolated by key (`dev/terraform.tfstate`, `prod/terraform.tfstate`).

```
management account
└── S3: hello-platform-tfstate-977145922427
    ├── dev/terraform.tfstate   ← written by dev deploy role
    └── prod/terraform.tfstate  ← written by prod deploy role
```

DynamoDB in the management account provides distributed locking — `terraform apply` in two environments simultaneously cannot corrupt each other's state.

#### Variable strategy

Each `environments/<env>/` has:
- `variables.tf` — declares inputs with types and descriptions
- `terraform.tfvars` — sets environment-specific values (region, instance type, alarm email)
- `backend.tf` — hardcoded state bucket path (intentional — avoids interpolation in backend blocks)
- `outputs.tf` — exposes values the CI/CD pipeline reads (`eks_cluster_name`, `ecr_repository_url`, `acm_certificate_arn`, `lbc_role_arn`)

---

### AWS Organizations (multi-account)

Separate AWS accounts provide blast-radius isolation that resource naming cannot:

| Concern | Single account | Multi-account |
|---|---|---|
| `terraform destroy` blast radius | Destroys prod if wrong env | Impossible by design |
| IAM boundaries | Soft (naming convention) | Hard (account boundary) |
| Billing / cost attribution | Mixed | Per-account Cost Explorer |
| Compliance (SCPs) | Same policies for all | Stricter SCPs on prod OU |

Management account holds only Terraform state, OIDC providers, and Organizations management. No workloads run there.

### Compute — EKS over ECS/Fargate

Amrize is migrating to GCP. Kubernetes Deployments, Services, and IRSA map 1:1 to GKE/Workload Identity. ECS task definitions do not.

| Concern | ECS/Fargate | **EKS** |
|---|---|---|
| Multi-cloud portability | None | **Full — same manifests on GKE** |
| Pod identity | Task role (AWS only) | **IRSA → GKE Workload Identity** |
| Ingress | ALB (AWS only) | **ALB (AWS) / GKE Ingress (GCP)** |
| Approx. cost | ~$50/month | ~$150/month |

The $100/month premium buys a portable platform that migrates to GKE without pod-level manifest rewrites.

### Ingress — AWS Load Balancer Controller

AWS LBC provisions an ALB entirely from the Kubernetes Ingress resource — no manual AWS console steps. The same Ingress annotations pattern works on GKE via the GKE Ingress controller. WAF v2 Regional scope is attached directly to the ALB via the `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation (OWASP rules, Log4Shell, IP reputation, rate limiting). See `terraform/modules/waf/main.tf` for rule definitions.

### Rolling update strategy — `maxUnavailable=1, maxSurge=0`

Default Kubernetes rolling update (`maxSurge=1`) requires capacity for 3 pods simultaneously on a single `t3.small` node. Setting `maxSurge=0` terminates one old pod before creating the new one, fitting within the node's capacity. Production uses multi-node groups where the default surge strategy works without this constraint.

### Reusable Platform Capabilities

The modules and patterns here are the standardizable artifacts. A new team onboards by creating `environments/<team>/main.tf`, calling the existing modules, and pointing `backend.tf` at the centralized state bucket. The platform team owns the modules; product teams own their environment config.

| Capability | Artifact | What any team gets |
|---|---|---|
| Hardened EKS cluster | `modules/eks/` | IMDSv2, KMS etcd encryption, OIDC, CW addon — secure by default |
| Least-privilege pod identity | `modules/iam/` | IRSA role scoped to exact service account — no node-level keys |
| Zero-credential CI/CD | `terraform/github-oidc/` + `ci.yml`/`deploy.yml` | OIDC federation, no stored IAM keys, ever |
| WAF baseline | `modules/waf/` | 4-rule WebACL (OWASP, Log4Shell, IP reputation, rate limit) — opt-in per ALB |
| Observability baseline | `modules/observability/` | Log groups, GuardDuty, CloudTrail, SNS alarm — compliance floor per account |
| Namespace isolation | `k8s/networkpolicy.yaml` + `resourcequota.yaml` | Default-deny-all + resource caps — packageable as a Helm baseline chart |
| Account isolation | `terraform/management/` | Per-team AWS account, isolated blast radius, per-account billing |

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

## Known Limitations & Deliberate Omissions

The challenge explicitly rewards prioritization. The items below were either deliberately omitted or are known gaps:

### Deliberate omissions

| Item | Why omitted |
|---|---|
| Custom domain + Route53 | Requires owning a domain. Self-signed ACM cert demonstrates the TLS pattern; DNS validation is a two-line swap once a domain exists. |
| HPA (Horizontal Pod Autoscaler) | `replicas: 2` provides basic HA. HPA is the natural next step, documented in Reliability & Operations above. |
| Karpenter | Managed node groups are simpler to reason about. Karpenter is a prod optimization (bin-packing + spot), not a platform foundation requirement. |
| External DNS | Automates Route53 from Ingress resources. Omitted because no custom domain exists. |
| SCP enforcement | AWS Organizations is set up; SCPs on prod OU (deny delete KMS, deny disable CloudTrail) are the obvious next step. |
| Secrets Manager | The app is stateless — no secrets to manage. The `iam/main.tf` grants SSM access for future secrets; Secrets Manager is one Terraform resource away. |

### Scope acknowledgment

The challenge says "for a dev environment, a single log group, one metric or alarm, and a working /health endpoint fully satisfies observability." This implementation goes further (GuardDuty, CloudTrail, VPC Flow Logs, multi-account). The additional investment was made to demonstrate the platform-level thinking Amrize evaluates for a Cloud Engineering Leader role — not to complete more checklist items, but to show what a durable, reusable foundation looks like. The modules and patterns are the deliverable; the hello-platform app is the vehicle.

### Technical debt

| Item | Status | Notes |
|---|---|---|
| HTTPS certificate | Self-signed (active) | Browser shows warning. Replace with ACM DNS-validated cert + custom domain for trusted TLS. |
| Multi-AZ NAT Gateway | Dev uses single NAT (~$45/month) | Two-line change in `networking/main.tf` for prod HA. |
| Dev HTTPS endpoint | ALB rebuilding after ingress-class migration | `kubernetes.io/ingress.class` annotation was deprecated in newer LBC versions; migrated to `spec.ingressClassName`. |

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
