# What this stack uses and does not own. Everything here is found by name,
# so the stack can be planned alone.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

# --- Where the status host sits ---------------------------------------------

# The host was launched by hand into the testnet VPC. That VPC, its subnets
# and the security group `testnet-ssh` were made by dash-network-deploy,
# which is retired and must not be applied again (its state still describes
# them). They are looked up, never adopted: testnet's 84 nodes share them.
data "aws_vpc" "testnet" {
  tags = { Name = "dn-testnet" }
}

data "aws_subnet" "testnet_public2" {
  vpc_id = data.aws_vpc.testnet.id
  tags   = { Name = "testnet-public2" }
}

# SSH (22, 2022) from anywhere and the Docker API from inside the VPC. Every
# testnet node carries it, and so does the status host: it is the only thing
# that opens the host's port 22.
data "aws_security_group" "testnet_ssh" {
  vpc_id = data.aws_vpc.testnet.id
  name   = "testnet-ssh"
}

# --- The account stack's things ---------------------------------------------

# The owned address range (68.67.122.0/24) as it is offered in us-west-2. An
# IPAM is read in its home region.
data "aws_vpc_ipam_pool" "owned" {
  region = "us-east-1"

  filter {
    name   = "description"
    values = ["byoip-us-west-2"]
  }
}

# The account's GitHub Actions identity provider.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# --- The dns stack's zone ---------------------------------------------------

# This stack owns one record in it (dns.tf). The console itself writes the
# devnet names into the same zone while it runs.
data "aws_route53_zone" "networks" {
  name = "networks.dash.org"
}

# --- What a new host starts from --------------------------------------------

# Canonical's current Ubuntu 24.04 image for ARM64, from the public parameter
# Canonical publishes. It is an image id, not a secret.
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/noble/stable/current/arm64/hvm/ebs-gp3/ami-id"
}
