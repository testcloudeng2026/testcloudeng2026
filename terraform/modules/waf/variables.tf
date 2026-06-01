variable "name" {
  description = "WAF WebACL name"
  type        = string
}

variable "scope" {
  description = "WAF WebACL scope: REGIONAL (ALB/API GW) or CLOUDFRONT"
  type        = string
  default     = "REGIONAL"
}

variable "rate_limit" {
  description = "Max requests per 5-minute window per source IP before blocking"
  type        = number
  default     = 2000
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
