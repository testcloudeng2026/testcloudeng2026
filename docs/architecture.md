# Architecture Diagram

## Network & Application Flow

```
                         ┌──────────────────────────────┐
  Internet               │  AWS CloudFront (Global Edge) │
     │                   │  ┌──────────────────────────┐ │
     │  HTTPS (443)      │  │   AWS WAF WebACL          │ │
     ▼                   │  │   • Common rule set       │ │
 ┌───────┐               │  │   • Known bad inputs      │ │
 │ Users │──────────────▶│  │   • IP reputation list    │ │
 └───────┘               │  │   • Rate limit (2000/5min)│ │
                         │  └──────────────┬────────────┘ │
                         │  Shield Standard│(free DDoS)   │
                         └─────────────────┼──────────────┘
                                           │ HTTPS origin
                        ┌──────────────────▼──────────────────────────────────┐
                        │           AWS VPC (10.0.0.0/21 — 2,048 IPs)        │
                        │                                                     │
                        │  ┌──────────────────────────────────────────────┐  │
                        │  │  Public Subnets /27 — 32 IPs each (AZ-a/b)  │  │
                        │  │                                              │  │
                        │  │   ┌─────────────┐       ┌──────────────┐    │  │
                        │  │   │  NAT Gateway│       │     NLB      │    │  │
                        │  │   │  (AZ-a)    │       │(NGINX Ingress│    │  │
                        │  │   └──────┬──────┘       │  Service)   │    │  │
                        │  │          │ (outbound)    └──────┬───────┘   │  │
                        │  └──────────┼────────────────────── ┼──────────┘  │
                        │             │                        │             │
                        │  ┌──────────┼────────────────────────┼──────────┐ │
                        │  │  Private Subnets /24 — 256 IPs each (AZ-a/b)│ │
                        │  │          ▼              NodePort  ▼          │ │
                        │  │   ┌─────────────────────────────────────┐    │ │
                        │  │   │          EKS Worker Nodes           │    │ │
                        │  │   │  ┌───────────────────────────────┐  │    │ │
                        │  │   │  │     NGINX Ingress Pod         │  │    │ │
                        │  │   │  └────────────────┬──────────────┘  │    │ │
                        │  │   │  ┌────────────────▼──────────────┐  │    │ │
                        │  │   │  │     hello-platform Pod (×2)   │  │    │ │
                        │  │   │  │  NetworkPolicy: deny-all +    │  │    │ │
                        │  │   │  │  allow only from ingress-nginx │  │    │ │
                        │  │   │  │  IRSA → SSM /hello-platform/* │  │    │ │
                        │  │   │  └───────────────────────────────┘  │    │ │
                        │  │   └─────────────────────────────────────┘    │ │
                        │  └──────────────────────────────────────────────┘ │
                        └─────────────────────────────────────────────────────┘
```

## Supporting Services

```
  ┌──────────────────────────────────────────────────────────────┐
  │                     AWS Managed Services                     │
  │                                                              │
  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
  │  │     ECR     │  │  CloudWatch  │  │   S3 + DynamoDB    │  │
  │  │  (images)   │  │  (logs +     │  │  (Terraform state  │  │
  │  │  scan on    │  │   alarm on   │  │  + state locking)  │  │
  │  │   push      │  │  restarts)   │  │                    │  │
  │  └──────┬──────┘  └──────────────┘  └────────────────────┘  │
  │         │ pull                                                │
  │         ▼                                                     │
  │   Worker Nodes                                                │
  └──────────────────────────────────────────────────────────────┘
```

## Security Boundaries

| Boundary | Rule |
|---|---|
| NLB → Nodes | NodePort traffic only (managed by NGINX Ingress) |
| Nodes | Private subnets — no public IP |
| Outbound | Via single NAT Gateway (dev); prod: one per AZ |
| Pod IAM | IRSA — scoped to SSM `/hello-platform/*` only |
| State | S3 encryption + versioning + public access block |
| CI/CD | GitHub OIDC — no stored IAM credentials |

## Multi-Cloud Path (AWS → GCP)

```
  AWS (now)                        GCP (future)
  ─────────────────────────────    ─────────────────────────────
  EKS                          →   GKE
  IRSA annotation              →   iam.gke.io/gcp-service-account
  ECR                          →   Artifact Registry
  CloudWatch                   →   Cloud Logging / Monitoring
  NGINX Ingress (unchanged)    →   NGINX Ingress (unchanged)
  k8s/ manifests (unchanged)   →   k8s/ manifests (unchanged)
  S3 backend                   →   GCS backend
```
