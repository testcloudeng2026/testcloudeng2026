# Architecture

## Account Structure (AWS Organizations)

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  AWS Organizations                                                  │
  │                                                                     │
  │  ┌──────────────────────────────────────────────────────────────┐   │
  │  │  Management Account (977145922427)                           │   │
  │  │  • Terraform state  — S3 hello-platform-tfstate-977145922427 │   │
  │  │  • State locking    — DynamoDB hello-platform-tfstate-lock   │   │
  │  │  • KMS CMK          — encrypts state + cross-account access  │   │
  │  │  • OIDC provider    — GitHub Actions federation              │   │
  │  │  • No workloads run here                                     │   │
  │  └──────────────────────────────────────────────────────────────┘   │
  │                                                                     │
  │  ┌─────────────────────────────┐  ┌──────────────────────────────┐  │
  │  │  OU: dev                    │  │  OU: prod                    │  │
  │  │  Account: 196209078497      │  │  Account: 590423939674       │  │
  │  │  hello-platform-dev         │  │  hello-platform-prod         │  │
  │  │  State key: dev/tf.tfstate  │  │  State key: prod/tf.tfstate  │  │
  │  └─────────────────────────────┘  └──────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────┘
```

Member accounts access the management account state bucket via cross-account S3 bucket policy and KMS key policy. No credentials are stored — GitHub Actions assumes account-specific roles via OIDC.

---

## Network & Application Flow (per environment account)

```
  Internet
     │
     │  HTTPS (443) — self-signed cert
     │  HTTP  (80)  — redirects to HTTPS (301)
     ▼
 ┌───────┐
 │ Users │──────────────────────────────────────────────────────────────┐
 └───────┘                                                              │
                        ┌──────────────────────────────────────────────▼──┐
                        │           AWS VPC (10.0.0.0/21 — 2,048 IPs)    │
                        │                                                 │
                        │  ┌────────────────────────────────────────────┐ │
                        │  │  Public Subnets /27 — 32 IPs each (AZ-a/b) │ │
                        │  │                                            │ │
                        │  │   ┌─────────────┐   ┌──────────────────┐  │ │
                        │  │   │  NAT Gateway│   │  ALB + WAF       │  │ │
                        │  │   │  (AZ-a)     │   │  (AWS LBC)       │  │ │
                        │  │   │             │   │  • CommonRuleSet  │  │ │
                        │  │   └──────┬──────┘   │  • BadInputs     │  │ │
                        │  │          │(outbound) │  • IPReputation  │  │ │
                        │  │          │           │  • Rate limit    │  │ │
                        │  └──────────┼───────────┴──────┬───────────┘  │ │
                        │             │                   │ NodePort     │ │
                        │  ┌──────────┼───────────────────┼──────────┐  │ │
                        │  │  Private Subnets /24 — 256 IPs (AZ-a/b) │  │ │
                        │  │          ▼                   ▼           │  │ │
                        │  │   ┌───────────────────────────────────┐  │  │ │
                        │  │   │        EKS Worker Nodes           │  │  │ │
                        │  │   │  (t3.small dev / t3.medium prod)  │  │  │ │
                        │  │   │  ┌─────────────────────────────┐  │  │  │ │
                        │  │   │  │  hello-platform Pod (×2)    │  │  │  │ │
                        │  │   │  │  NetworkPolicy: deny-all +  │  │  │  │ │
                        │  │   │  │  allow from VPC CIDR :8080  │  │  │  │ │
                        │  │   │  │  IRSA → SSM /hello-platform │  │  │  │ │
                        │  │   │  └─────────────────────────────┘  │  │  │ │
                        │  │   └───────────────────────────────────┘  │  │ │
                        │  └───────────────────────────────────────────┘  │ │
                        └─────────────────────────────────────────────────┘ │
                                                                             │
```

---

## Supporting Services

```
  ┌───────────────────────────────────────────────────────────────────────────┐
  │  Management Account (977145922427)                                        │
  │                                                                           │
  │  ┌─────────────────────────────────┐   ┌───────────────────────────────┐ │
  │  │  S3 + DynamoDB                  │   │  KMS CMK                      │ │
  │  │  Terraform state (all envs)     │   │  Encrypts: S3 state, cross-   │ │
  │  │  dev/terraform.tfstate          │   │  account decrypt via key policy│ │
  │  │  prod/terraform.tfstate         │   └───────────────────────────────┘ │
  │  └─────────────────────────────────┘                                     │
  └───────────────────────────────────────────────────────────────────────────┘

  ┌───────────────────────────────────────────────────────────────────────────┐
  │  Member Account (dev / prod)                                              │
  │                                                                           │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  ┌─────────────┐  │
  │  │     ECR     │  │  CloudWatch  │  │   GuardDuty   │  │ CloudTrail  │  │
  │  │  (images)   │  │  logs +      │  │  S3 + K8s     │  │  mgmt +     │  │
  │  │  scan on    │  │  restart     │  │  audit +      │  │  data events│  │
  │  │  push       │  │  alarm → SNS │  │  malware      │  │             │  │
  │  └──────┬──────┘  └──────────────┘  └───────────────┘  └─────────────┘  │
  │         │ pull                                                            │
  │         ▼                                                                 │
  │   EKS Worker Nodes                                                        │
  └───────────────────────────────────────────────────────────────────────────┘
```

---

## CI/CD & Branching

```
  Developer
     │
     ├─ git checkout -b feature/my-change
     │
     ▼
  feature/* branch
     │
     └─ Pull Request → develop
              │
              ├── CI (ci.yml) ─────────────────────────────────────────────┐
              │     • Terraform Plan → posts diff as PR comment            │
              │     • Docker build + Trivy (blocks on HIGH/CRITICAL CVE)   │
              │     • kubectl apply --dry-run=client                       │
              │     All 3 must pass + 1 reviewer approval                  │
              └──────────────────────────────────────────────────────────── ┘
                       │ merge
                       ▼
                  develop branch
                       │
                       └─ deploy.yml (deploy-dev job) ──────────────────────┐
                             • tf apply → VPC, EKS, ECR, WAF, LBC role      │
                             • Docker build + Trivy + ECR push               │
                             • Install AWS Load Balancer Controller           │
                             • kubectl apply (rolling update)                │
                             • Register node in ALB + verify health          │
                             Deploys to account 196209078497                 │
                       ────────────────────────────────────────────────────┘
                       │
                       └─ Pull Request → main
                                │
                                ├── CI (same checks) + 1 reviewer approval
                                └──────── merge
                                              │
                                         ⏸ Approval gate
                                         (manual click in GitHub)
                                              │
                                         deploy.yml (deploy-prod job)
                                         Deploys to account 590423939674
```

---

## Security Boundaries

| Boundary | Rule |
|---|---|
| Internet → app | HTTPS (443) via ALB — WAF inspects every request. HTTP (80) redirects 301 to HTTPS |
| ALB → Nodes | NodePort range (30000-32767) only from VPC CIDR 10.0.0.0/21 |
| Nodes | Private subnets — no public IP assigned |
| Node metadata | IMDSv2 required (`http_tokens = required`) — blocks SSRF credential theft |
| Pod IAM | IRSA — each pod assumes a scoped role, no shared node instance profile |
| Pod network | NetworkPolicy default-deny-all + allow from VPC CIDR on port 8080 + DNS/443 egress |
| Container | uid=1000, `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL capabilities |
| Secrets at rest | KMS CMK: EKS etcd encryption, EBS node volumes, S3 state bucket |
| CI/CD credentials | GitHub OIDC only — zero IAM access keys stored in GitHub secrets |
| Deploy role scope | Trust policy locked to `repo:org/repo:environment:dev` (or prod) — no wildcard |
| PR to develop | 1 reviewer + 3 CI checks required |
| PR to main | 1 reviewer + 3 CI checks + dismiss stale reviews |
| Prod deploy | Additional manual approval gate in GitHub environment |
| State access | Cross-account S3 + KMS policy — only deploy roles of member accounts can read/write |
| Image scanning | Trivy blocks push on HIGH/CRITICAL CVEs + ECR scan on push |
| Threat detection | GuardDuty: S3 data events, K8s audit logs, EBS malware protection |
| Audit trail | CloudTrail management + data events per account |

---

## Multi-Cloud Path (AWS → GCP)

```
  AWS (now)                        GCP (future)
  ─────────────────────────────    ─────────────────────────────
  EKS                          →   GKE
  IRSA annotation              →   iam.gke.io/gcp-service-account
  ECR                          →   Artifact Registry
  CloudWatch                   →   Cloud Logging / Monitoring
  AWS Load Balancer Controller →   GKE Ingress / Gateway API
  k8s/ Deployment/Service      →   k8s/ Deployment/Service (unchanged)
  S3 backend                   →   GCS backend
  AWS Organizations            →   GCP Resource Hierarchy (folders)
```

Kubernetes Deployments, Services, ConfigMaps, and IRSA service account annotations require minimal changes to run on GKE. The main migration work is the infrastructure layer (Terraform providers) and the ingress controller (ALB → GKE Ingress).
