terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "dash-terraform-state-854439639386"
    key          = "dash-infra/quorum.tfstate"
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
      Stack     = "quorum"
    }
  }
}

# The same account without the default tags, for the two CloudFormation
# stacks only: modules/quorum-network/cdn.tf says why.
provider "aws" {
  alias  = "no_default_tags"
  region = "us-west-2"
}
