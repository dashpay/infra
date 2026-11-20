# The address block Dash Core Group owns, 68.67.122.0/24, and the IPAM that
# hands it out. Every public host in the account takes its Elastic IP from
# here instead of from Amazon, so an address stays ours when a host is
# rebuilt and DNS does not have to follow.
#
#   IPAM `org-ipam` (home region us-east-1)
#   └─ public scope (made by AWS with the IPAM)
#      └─ pool `byoip-top-level`      68.67.122.0/24, no region
#         └─ pool `byoip-us-west-2`   68.67.122.0/24, for EC2 in us-west-2
#            └─ Elastic IPs (each belongs to the stack that uses it)
#
# Other stacks find the pool by its description, not by id:
#
#   data "aws_vpc_ipam_pool" "owned" {
#     region = "us-east-1"
#     filter {
#       name   = "description"
#       values = ["byoip-us-west-2"]
#     }
#   }
#
# NOTHING HERE MAY BE REPLACED. A plan that wants to destroy or replace a
# pool or one of the two CIDRs would take the block away from every address
# allocated from it. Terraform cannot put it back alone: bringing the block
# into AWS needs a message signed with the private key of the certificate in
# the block's ARIN record (README, "Rebuild from nothing").
#
# Everything about an IPAM is managed through its home region, including the
# pool whose addresses are used in us-west-2.

locals {
  ipam_region = "us-east-1"
  owned_cidr  = "68.67.122.0/24"
}

resource "aws_vpc_ipam" "org" {
  region      = local.ipam_region
  description = "org-ipam"

  # The advanced tier is what allows bringing our own addresses.
  tier = "advanced"

  operating_regions {
    region_name = "us-east-1"
  }

  operating_regions {
    region_name = "us-west-2"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# The IPAM's two default scopes (public and private) are made and removed by
# AWS together with the IPAM and cannot be created by Terraform, so they are
# not resources here. The private scope is empty.

resource "aws_vpc_ipam_pool" "top_level" {
  region        = local.ipam_region
  description   = "byoip-top-level"
  ipam_scope_id = aws_vpc_ipam.org.public_default_scope_id

  address_family   = "ipv4"
  public_ip_source = "byoip"

  lifecycle {
    prevent_destroy = true
  }
}

# The block itself, as brought into AWS. On an existing block there is
# nothing to change. Provisioning it anew needs a `cidr_authorization_context`
# block here for that one apply (README).
resource "aws_vpc_ipam_pool_cidr" "top_level" {
  region       = local.ipam_region
  ipam_pool_id = aws_vpc_ipam_pool.top_level.id
  cidr         = local.owned_cidr

  lifecycle {
    prevent_destroy = true

    # The signed message that proves ownership is used once, when the block
    # is provisioned, and AWS never returns it. Terraform would read "the
    # block was written and is now gone" as a reason to replace the CIDR, so
    # the difference is ignored: the block can be added for a rebuild and
    # taken out again afterwards.
    ignore_changes = [cidr_authorization_context]
  }
}

# The pool that Elastic IPs in us-west-2 are allocated from.
resource "aws_vpc_ipam_pool" "us_west_2" {
  region              = local.ipam_region
  description         = "byoip-us-west-2"
  ipam_scope_id       = aws_vpc_ipam.org.public_default_scope_id
  source_ipam_pool_id = aws_vpc_ipam_pool.top_level.id

  address_family   = "ipv4"
  public_ip_source = "byoip"
  locale           = "us-west-2"
  aws_service      = "ec2"

  lifecycle {
    prevent_destroy = true
  }
}

# The whole block is given to us-west-2. This is also what registers it with
# EC2 there; announcing it to the internet is a separate step that Terraform
# has no resource for (README).
resource "aws_vpc_ipam_pool_cidr" "us_west_2" {
  region       = local.ipam_region
  ipam_pool_id = aws_vpc_ipam_pool.us_west_2.id
  cidr         = local.owned_cidr

  # The block must be in the parent pool before a part of it can be given
  # to this one.
  depends_on = [aws_vpc_ipam_pool_cidr.top_level]

  lifecycle {
    prevent_destroy = true
  }
}

output "owned_address_pool" {
  description = "The owned address block and the pool Elastic IPs come from."
  value = {
    cidr    = aws_vpc_ipam_pool_cidr.us_west_2.cidr
    pool_id = aws_vpc_ipam_pool.us_west_2.id
    locale  = aws_vpc_ipam_pool.us_west_2.locale
    ipam_id = aws_vpc_ipam.org.id
  }
}
