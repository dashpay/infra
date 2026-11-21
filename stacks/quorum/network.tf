# The VPC the quorum list service runs in, for testnet and mainnet both.
#
# Every name here says "testnet": the VPC was built for the testnet service
# in July 2025 and mainnet was added beside it the same day. The names are
# kept as they are in AWS. Renaming a tag is harmless, but the load
# balancer's name cannot change without replacing it.
#
# Two public subnets (the load balancer, the bastion, the NAT gateway) and
# two private ones (the hosts and the EFS mount targets), in two zones.
#
# Other things live in this VPC that are not this stack's: see the README,
# "In this VPC but not in this stack".

locals {
  region = "us-east-1"

  vpc_cidr = "10.0.0.0/16"

  # Keyed by the number in each subnet's name.
  public_subnets = {
    "1" = { az = "us-east-1a", cidr = "10.0.1.0/24" }
    "2" = { az = "us-east-1b", cidr = "10.0.2.0/24" }
  }
  private_subnets = {
    "1" = { az = "us-east-1a", cidr = "10.0.10.0/24" }
    "2" = { az = "us-east-1b", cidr = "10.0.11.0/24" }
  }

  shared_tags = { Environment = "testnet" }
}

resource "aws_vpc" "main" {
  region               = local.region
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.shared_tags, { Name = "testnet-vpc" })
}

resource "aws_internet_gateway" "main" {
  region = local.region
  vpc_id = aws_vpc.main.id

  tags = merge(local.shared_tags, { Name = "testnet-igw" })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  region            = local.region
  vpc_id            = aws_vpc.main.id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  # As found: an instance launched here gets an Amazon address unless it
  # says otherwise. The bastion and the mainnet recovery host have one.
  map_public_ip_on_launch = true

  tags = merge(local.shared_tags, { Name = "testnet-public-subnet-${each.key}", Type = "public" })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  region            = local.region
  vpc_id            = aws_vpc.main.id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  tags = merge(local.shared_tags, { Name = "testnet-private-subnet-${each.key}", Type = "private" })
}

# The private subnets reach the internet through one NAT gateway in the
# first zone. Core's peers and every package download go through it, so its
# address is what the outside sees of the hosts.
resource "aws_eip" "nat" {
  region = local.region
  domain = "vpc"

  tags = merge(local.shared_tags, { Name = "testnet-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  region        = local.region
  subnet_id     = aws_subnet.public["1"].id
  allocation_id = aws_eip.nat.id

  tags = merge(local.shared_tags, { Name = "testnet-nat-gateway" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  region = local.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.shared_tags, { Name = "testnet-public-rt" })
}

resource "aws_route_table" "private" {
  region = local.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.shared_tags, { Name = "testnet-private-rt" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  region         = local.region
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  region         = local.region
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
