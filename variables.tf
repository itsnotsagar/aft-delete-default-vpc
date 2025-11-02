variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "eu-west-1"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project   = "aft-delete-default-vpc"
    ManagedBy = "terraform"
  }
}

# Defining Account Id
variable "account_id" {
  type    = string
  default = "123456789012" #CT Account ID
}
