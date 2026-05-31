variable "name" {
  description = "KMS key alias name (e.g. hello-platform-eks)"
  type        = string
}

variable "description" {
  description = "Human-readable description of what this key protects"
  type        = string
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
