# SQS Queue for message passing
resource "aws_sqs_queue" "aft_vpc_cleanup_queue" {
  name                       = "aft-default-vpc-cleanup-queue"
  visibility_timeout_seconds = 300
  delay_seconds              = 180 # 3 minutes delay before messages are available for processing
  kms_master_key_id          = "alias/aws/sqs"

  tags = {
    Name = "aft VPC Cleanup Queue"
  }
}

# EventBridge Rule for CreateManagedAccount events
resource "aws_cloudwatch_event_rule" "aft_create_managed_account" {
  name        = "aft-vpc-cleanup-create-managed-account"
  description = "Trigger VPC cleanup on CreateManagedAccount events with SUCCEEDED state"

  event_pattern = jsonencode({
    source      = ["aws.controltower"]
    detail-type = ["AWS Service Event via CloudTrail"]
    detail = {
      eventName = ["CreateManagedAccount"]
    }
  })
}

# CloudWatch Log Group for Producer Lambda
resource "aws_cloudwatch_log_group" "aft_producer_lambda_logs" {
  name              = "/aws/lambda/aft-delete-default-vpc-producer"
  retention_in_days = 90

  tags = var.tags
}

# Producer Lambda Function
resource "aws_lambda_function" "aft_vpc_cleanup_producer" {
  filename         = data.archive_file.aft_producer_lambda_zip.output_path
  function_name    = "aft-delete-default-vpc-producer"
  role             = aws_iam_role.aft_producer_lambda_role.arn
  handler          = "aft-delete-default-vpc-producer.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128
  source_code_hash = data.archive_file.aft_producer_lambda_zip.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.aft_vpc_cleanup_queue.url
      LOG_LEVEL     = "INFO"
    }
  }

  depends_on = [
    data.archive_file.aft_producer_lambda_zip,
    aws_cloudwatch_log_group.aft_producer_lambda_logs
  ]
}

# CloudWatch Log Group for Consumer Lambda
resource "aws_cloudwatch_log_group" "aft_consumer_lambda_logs" {
  name              = "/aws/lambda/aft-delete-default-vpc-consumer"
  retention_in_days = 90

  tags = var.tags
}

# Consumer Lambda Function
resource "aws_lambda_function" "aft_vpc_cleanup_consumer" {
  filename         = data.archive_file.aft_consumer_lambda_zip.output_path
  function_name    = "aft-delete-default-vpc-consumer"
  role             = aws_iam_role.aft_consumer_lambda_role.arn
  handler          = "aft-delete-default-vpc-consumer.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  source_code_hash = data.archive_file.aft_consumer_lambda_zip.output_base64sha256

  environment {
    variables = {
      LOG_LEVEL = "INFO"
    }
  }

  depends_on = [
    data.archive_file.aft_consumer_lambda_zip,
    aws_cloudwatch_log_group.aft_consumer_lambda_logs
  ]
}

# EventBridge target for producer Lambda
resource "aws_cloudwatch_event_target" "aft_producer_lambda_target" {
  rule      = aws_cloudwatch_event_rule.aft_create_managed_account.name
  target_id = "AFTVPCCleanupProducerTarget"
  arn       = aws_lambda_function.aft_vpc_cleanup_producer.arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "aft_allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aft_vpc_cleanup_producer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aft_create_managed_account.arn
}

# SQS trigger for consumer Lambda
resource "aws_lambda_event_source_mapping" "aft_sqs_trigger" {
  event_source_arn = aws_sqs_queue.aft_vpc_cleanup_queue.arn
  function_name    = aws_lambda_function.aft_vpc_cleanup_consumer.arn
  batch_size       = 1
}

# IAM Role for Producer Lambda
resource "aws_iam_role" "aft_producer_lambda_role" {
  name = "aft-delete-default-vpc-producer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Role for Consumer Lambda
resource "aws_iam_role" "aft_consumer_lambda_role" {
  name = "aft-delete-default-vpc-consumer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Producer Lambda
resource "aws_iam_role_policy" "aft_producer_lambda_policy" {
  name = "aft-delete-default-vpc-producer-policy"
  role = aws_iam_role.aft_producer_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.aft_vpc_cleanup_queue.arn
      }
    ]
  })
}

# IAM Policy for Consumer Lambda
resource "aws_iam_role_policy" "aft_consumer_lambda_policy" {
  name = "aft-delete-default-vpc-consumer-policy"
  role = aws_iam_role.aft_consumer_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.aft_vpc_cleanup_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sts:AssumeRole"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::*:role/AWSControlTowerExecution"
      }
    ]
  })
}
