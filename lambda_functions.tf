# Lambda function packaging

# Archive producer Lambda
data "archive_file" "aft_producer_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/producer"
  output_path = "${path.module}/lambda/aft-delete-default-vpc-producer.zip"
}

# Archive consumer Lambda
data "archive_file" "aft_consumer_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/consumer"
  output_path = "${path.module}/lambda/aft-delete-default-vpc-consumer.zip"
}
