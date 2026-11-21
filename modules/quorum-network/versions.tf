terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"

      # A second configuration of the same provider, without default tags.
      # Only the CloudFormation stack uses it: cdn.tf says why.
      configuration_aliases = [aws.no_default_tags]
    }
  }
}
