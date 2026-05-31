variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version to deploy"
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "VPC ID for the cluster"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (needed for control plane endpoint and NLB)"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for worker nodes"
  type        = list(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "node_desired_count" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 1
}

variable "node_min_count" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Restrict to CI runner IPs or set endpoint_public_access=false for VPN-only access."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "kms_key_arn" {
  description = "KMS key ARN used to envelope-encrypt Kubernetes secrets at rest in etcd"
  type        = string
}

variable "ebs_volume_size_gb" {
  description = "Root EBS volume size for worker nodes (GiB)"
  type        = number
  default     = 20
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
