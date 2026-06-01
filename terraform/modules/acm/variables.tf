variable "common_name" {
  description = "Common name (CN) for the self-signed certificate"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the ACM certificate"
  type        = map(string)
  default     = {}
}
