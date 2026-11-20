# What this stack uses and does not own.
#
# Every host here is in the account's default VPC, in the default subnet of
# its zone. The VPC and its subnets belong to nobody's Terraform: they are
# looked up, not adopted.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default" {
  for_each = toset(["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"])

  vpc_id            = data.aws_vpc.default.id
  availability_zone = each.key
  default_for_az    = true
}

# The owned address range (68.67.122.0/24) as it is offered in us-west-2.
# The pool belongs to the account stack. An IPAM is read in its home region.
data "aws_vpc_ipam_pool" "owned" {
  region = "us-east-1"

  filter {
    name   = "description"
    values = ["byoip-us-west-2"]
  }
}

# dashevo.org belongs to the dns stack.
data "aws_route53_zone" "dashevo" {
  name = "dashevo.org"
}
