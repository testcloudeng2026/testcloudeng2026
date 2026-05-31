output "log_group_name" {
  description = "CloudWatch log group for application container logs (written by Fluent Bit via Container Insights addon)"
  value       = aws_cloudwatch_log_group.app.name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = aws_sns_topic.alarms.arn
}
