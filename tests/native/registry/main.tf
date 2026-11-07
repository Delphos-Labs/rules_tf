terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.17.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
    }
  }
}
module "bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.2.2"
}
module "policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.2.3"
}
