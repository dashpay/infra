terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # The bucket is versioned; locking uses a lock file in the bucket itself.
  backend "s3" {
    bucket       = "dash-terraform-state-854439639386"
    key          = "dash-infra/services.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Source    = "dashpay/infra"
      Stack     = "services"
    }
  }
}
