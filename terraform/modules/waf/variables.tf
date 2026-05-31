variable "name" {
  description = "WAF WebACL name"
  type        = string
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
