terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # The bucket is versioned; locking uses a lock file in the bucket itself.
  backend "s3" {
    bucket       = "dash-terraform-state-854439639386"
    key          = "dash-infra/apt.tfstate"
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
      Stack     = "apt"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region

  # Both are written into every operator's dashmate.sources, which is a dpkg
  # conffile: an edited copy never receives a later change. They are final.
  hostname = "apt.services.dash.org"
  prefix   = "dashmate"
}
