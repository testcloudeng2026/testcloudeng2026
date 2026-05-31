variable "name" {
  description = "Name prefix for observability resources"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "alarm_email" {
  description = "Email for alarm notifications. Leave empty to create the SNS topic without a subscription."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
