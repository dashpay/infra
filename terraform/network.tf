# A small VPC for shared services, apart from the network VPCs (dn-testnet
# and friends), whose lifecycle follows the networks they hold.
#
# Public subnets only: every host here has its own Elastic IP, so there is
# no NAT gateway to pay for.

locals {
  services_vpc_cidr = "10.64.0.0/20"
  services_subnets = {
    a = { az = "us-west-2a", cidr = "10.64.0.0/24" }
    b = { az = "us-west-2b", cidr = "10.64.1.0/24" }
  }
}

resource "aws_vpc" "services" {
  cidr_block           = local.services_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "dash-services" }
}

resource "aws_internet_gateway" "services" {
  vpc_id = aws_vpc.services.id

  tags = { Name = "dash-services" }
}

resource "aws_subnet" "services" {
  for_each = local.services_subnets

  vpc_id            = aws_vpc.services.id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr

  # Hosts get an Elastic IP from the owned pool, never an Amazon address.
  map_public_ip_on_launch = false

  tags = { Name = "dash-services-public-${each.key}" }
}

resource "aws_route_table" "services" {
  vpc_id = aws_vpc.services.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.services.id
  }

  tags = { Name = "dash-services-public" }
}

resource "aws_route_table_association" "services" {
  for_each = aws_subnet.services

  subnet_id      = each.value.id
  route_table_id = aws_route_table.services.id
}

# The default security group allows nothing, so a host that is given no
# group of its own is unreachable rather than open.
resource "aws_default_security_group" "services" {
  vpc_id = aws_vpc.services.id

  tags = { Name = "dash-services-default-closed" }
}
