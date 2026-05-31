variable "name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /21 = 2,048 IPs — sized for enterprise IPAM allocation."
  type        = string
  default     = "10.0.0.0/21"
}

variable "azs" {
  description = "Availability zones to deploy into"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for public subnets (NAT Gateway + NLB only).
    /27 = 32 IPs per AZ — NLB and NAT GW each need 1 IP; ENIs a few more; 32 is sufficient.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/27", "10.0.0.32/27"]
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for private subnets (nodes + pods).
    /24 = 256 IPs per AZ — AWS VPC CNI assigns a real VPC IP to every pod;
    a busy t3.small node can hold ~11 pods, so 256 gives comfortable headroom for
    ~20 nodes before the subnet becomes a bottleneck.
  EOT
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.4.0/24"]
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
