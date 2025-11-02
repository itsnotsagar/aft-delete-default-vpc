terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.84.0"
      configuration_aliases = [aws]
    }
  }
  backend "s3" {
    bucket               = "aft-terraform-state-storage"
    key                  = "aft-delete-default-vpc.tfstate"
    region               = "eu-west-1"
    encrypt              = true
    use_lockfile         = false #S3 native locking
    workspace_key_prefix = "aft-delete-default-vpc"
  }
}

provider "aws" {
  region = var.aws_region
}

# Target
provider "aws" {
  alias  = "target"
  region = var.aws_region
  assume_role {
    role_arn    = "arn:aws:iam::${var.account_id}:role/AWSAFTExecution"
    external_id = "ASSUME_ROLE_ON_TARGET_ACC"
  }
}
