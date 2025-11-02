# Outputs

output "sqs_queue_url" {
  description = "URL of the SQS queue for VPC cleanup messages"
  value       = aws_sqs_queue.aft_vpc_cleanup_queue.url
}

output "sqs_queue_arn" {
  description = "ARN of the SQS queue for VPC cleanup messages"
  value       = aws_sqs_queue.aft_vpc_cleanup_queue.arn
}

output "producer_lambda_arn" {
  description = "ARN of the producer Lambda function"
  value       = aws_lambda_function.aft_vpc_cleanup_producer.arn
}

output "consumer_lambda_arn" {
  description = "ARN of the consumer Lambda function"
  value       = aws_lambda_function.aft_vpc_cleanup_consumer.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule for CreateManagedAccount events"
  value       = aws_cloudwatch_event_rule.aft_create_managed_account.arn
}
