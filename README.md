# AFT Default VPC Cleanup for Control Tower

Automated removal of default VPCs from newly created Control Tower managed accounts using an EventBridge → Lambda (producer) → SQS → Lambda (consumer) pattern.

## Overview

When Control Tower finishes creating a managed account, an EventBridge rule triggers a producer Lambda that enqueues the account details. After a 3‑minute delay, a consumer Lambda assumes the `AWSControlTowerExecution` role in the new account and deletes default VPCs in all opted‑in regions except Control Tower–governed regions.

## Architecture

- EventBridge rule matches Control Tower `CreateManagedAccount` events
- Producer Lambda (`aft-delete-default-vpc-producer`) parses the event and sends a message to SQS
- SQS queue (`aft-default-vpc-cleanup-queue`) introduces a 3‑minute delay for stabilization
- Consumer Lambda (`aft-delete-default-vpc-consumer`) consumes SQS, assumes `AWSControlTowerExecution` in the target account, and deletes default VPCs

Default VPCs are skipped in CT-governed regions:
- us-east-1, us-west-2, ap-south-1, ap-northeast-2, eu-west-1

## Repository layout

```
├── provider.tf                 # Backend + providers
├── main.tf                     # Core resources (SQS, EventBridge, Lambdas, IAM)
├── lambda_functions.tf         # Packaging Lambdas via archive_file
├── data.tf                     # Data sources (aws_partition)
├── variables.tf                # Inputs (region, tags, account_id)
├── outputs.tf                  # Useful outputs
├── .gitlab-ci.yml              # Plan/Apply pipeline
└── lambda/
    ├── producer/aft-delete-default-vpc-producer.py
    └── consumer/aft-delete-default-vpc-consumer.py
```

## Requirements

- Terraform >= 1.5 (tested with AWS provider >= 5.84.0)
- AWS CLI configured with permissions to create Lambda, SQS, EventBridge, and IAM
- Deployed in the Control Tower management account (to receive CT events)
- Target accounts must have the `AWSControlTowerExecution` role (created by CT)
- Python 3.12 runtime available in your region

## Backend and providers

The state is stored in S3 and the default AWS provider uses `var.aws_region`. A second provider (`aws.target`) is defined to assume an AFT execution role if needed.

```hcl
terraform {
  backend "s3" {
    bucket               = "aft-terraform-state-storage"
    key                  = "aft-delete-default-vpc.tfstate"
    region               = "eu-west-1"
    encrypt              = true
    use_lockfile         = false
    workspace_key_prefix = "aft-delete-default-vpc"
  }
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "target"
  region = var.aws_region
  assume_role {
    role_arn    = "arn:aws:iam::${var.account_id}:role/AWSAFTExecution"
    external_id = "ASSUME_ROLE_ON_TARGET_ACC"
  }
}
```

## Inputs

- `aws_region` (string, default: `eu-west-1`) – Deployment region
- `tags` (map(string)) – Default resource tags
- `account_id` (string) – Account ID for the `aws.target` alias (if used)

## Outputs

- `sqs_queue_url` – URL of the cleanup SQS queue
- `sqs_queue_arn` – ARN of the cleanup SQS queue
- `producer_lambda_arn` – ARN of the producer function
- `consumer_lambda_arn` – ARN of the consumer function
- `eventbridge_rule_arn` – ARN of the EventBridge rule

## Lambda environment variables

- Producer: `SQS_QUEUE_URL`, optional `LOG_LEVEL` (default `INFO`)
- Consumer: optional `LOG_LEVEL` (default `INFO`)

## CI/CD (GitLab)

Pipeline stages and behavior (`.gitlab-ci.yml`):

- Runner tag: `aws-runner`
- `terraform-plan`
  - Runs `terraform init` and `terraform plan -out=tfplan`
  - Artifacts: `tfplan`, `lambda/*.zip` (expire in 1 hour)
  - Rules: MR pipelines targeting `main` when `*.tf`, `lambda/**/*`, or `*.yml` change
- `terraform-apply`
  - Needs plan artifacts; runs on `main`
  - Executes `terraform apply tfplan`

## How to deploy (manual)

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Verifying the deployment

- CloudWatch log groups exist:
  - `/aws/lambda/aft-delete-default-vpc-producer`
  - `/aws/lambda/aft-delete-default-vpc-consumer`
- SQS queue exists: `aft-default-vpc-cleanup-queue`
- EventBridge rule exists: `aft-vpc-cleanup-create-managed-account` with the target set to the producer Lambda

## Test event (quick sample)

Minimal Control Tower success event to exercise the producer:

```json
{
  "source": "aws.controltower",
  "detail": {
    "eventName": "CreateManagedAccount",
    "serviceEventDetails": {
      "createManagedAccountStatus": {
        "state": "SUCCEEDED",
        "account": { "accountId": "111122223333", "accountName": "new-account" }
      }
    },
    "eventTime": "2025-10-17T11:10:11Z"
  }
}
```

## Security and IAM

- Producer role policy: CloudWatch Logs + `sqs:SendMessage` to the cleanup queue
- Consumer role policy: CloudWatch Logs + `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes` and `sts:AssumeRole` to `arn:aws:iam::*:role/AWSControlTowerExecution`
- The consumer assumes `AWSControlTowerExecution` in the target account and performs VPC cleanup there

## Troubleshooting

- Producer not triggered: verify EventBridge rule matches `CreateManagedAccount` events from Control Tower
- No message in SQS: check producer logs and that `SQS_QUEUE_URL` is set
- AccessDenied in consumer: confirm `AWSControlTowerExecution` exists in the target account and trust/permissions are intact
- VPC not deleted: check if the region is CT‑governed (intentionally skipped) or if the account isn’t opted‑in to that region

## Known caveats

- State locking: S3 backend uses `use_lockfile = false`; for reliable Terraform locking on S3, configure a DynamoDB lock table
- Event filtering: the EventBridge rule filters on event name; the producer enforces `state == SUCCEEDED`
- Delay: the 3‑minute SQS delay is intentional to allow account provisioning to complete; adjust `delay_seconds` if needed

## Cleanup

```bash
terraform destroy
```