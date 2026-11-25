# Where the console builds devnets.
#
# The console (`dashnet provision`) launches a devnet's instances into this
# one subnet, with this one security group and this one key pair, gives each
# an address from the owned pool and writes the devnet's names into
# networks.dash.org. The network around them is made once and stays: that
# is what is here.
#
# THE LINE BETWEEN TERRAFORM AND THE CONSOLE
#
#   Terraform (this file):  the VPC, the subnet, the internet gateway, the
#                           route table, the security group and its rules,
#                           the key pair. All carry `dashnet:purpose`.
#   The console:            every instance in the subnet, its disk, its
#                           Elastic IP, its DNS names. All carry
#                           `dashnet:managed-by = dash-network-go`.
#
# Nothing here names an instance, a volume or an address. The console's role
# cannot change anything in this file (host-role.tf gives it no permission
# to), and the engine reads the subnet, the group and the key pair before
# every launch and refuses if they are not as its settings say.
#
# THE IDS ARE IN THE CONSOLE'S SETTINGS. `dashpay/status` carries the VPC,
# subnet and security group ids and the key pair's name as defaults
# (`shared/settings.js`, `devnets`), and the settings file on the host
# repeats them. If any of these is ever recreated, put the new ids into
# Settings (output `devnet_scaffolding`) or no devnet can be created.

locals {
  devnets_tags = {
    Name              = "dashnet-devnets"
    "dashnet:purpose" = "console-devnets"
  }
}

resource "aws_vpc" "devnets" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = local.devnets_tags
}

# One subnet in one zone: every console devnet is in us-west-2a.
resource "aws_subnet" "devnets" {
  vpc_id            = aws_vpc.devnets.id
  availability_zone = "us-west-2a"
  cidr_block        = "10.42.0.0/20"

  # A node gets an Elastic IP from the owned pool, never an Amazon address.
  map_public_ip_on_launch = false

  tags = local.devnets_tags
}

resource "aws_internet_gateway" "devnets" {
  vpc_id = aws_vpc.devnets.id

  tags = local.devnets_tags
}

# The subnet's routes: the VPC itself and the internet. The table is managed
# whole, so a route added by hand is removed by the next apply. The console
# adds none.
resource "aws_route_table" "devnets" {
  vpc_id = aws_vpc.devnets.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.devnets.id
  }

  tags = local.devnets_tags
}

resource "aws_route_table_association" "devnets" {
  subnet_id      = aws_subnet.devnets.id
  route_table_id = aws_route_table.devnets.id
}

# --- The key pair ------------------------------------------------------------

# The public half of the agent's SSH key. The private half is on the status
# host only (/srv/dash-status/agent/id_ed25519) and is in no backup. Every
# devnet node is launched with this key pair, which is how the agent gets in.
#
# If the agent's key is ever replaced, change the public key here: that
# replaces the key pair under the same name and affects new launches only.
# Nodes that already run keep the old key in authorized_keys.
resource "aws_key_pair" "status_agent" {
  key_name   = "dash-status-agent"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2aY6fiTJ1FUbedt2QQ/nkPRErcWE7PUeMqfwemhLH7 dash-status-agent"

  tags = local.devnets_tags

  lifecycle {
    # public_key: when an existing key pair is adopted, the provider records
    # no public key for it, and would then replace the key pair to "set" the
    # same key. The key above is what EC2 returned for this key pair on
    # 2026-11-20 (DescribeKeyPairs with IncludePublicKey). To change the key
    # on purpose, remove this line for that apply.
    ignore_changes = [public_key]
  }
}

# --- The security group every devnet node carries ----------------------------

# Each rule is its own resource, so Terraform manages exactly the rules
# written here. A rule added by hand is not removed; it is simply not in
# this file.
resource "aws_security_group" "devnet_nodes" {
  name        = "dashnet-devnet-nodes"
  description = "Console-created devnets: fleet traffic, public DAPI/P2P/web, SSH from status host"
  vpc_id      = aws_vpc.devnets.id

  tags = local.devnets_tags
}

locals {
  # Open to the internet on every node. The key is the rule's description.
  devnet_public_ports = {
    "http-acme"      = 80    # Let's Encrypt challenges
    "https-services" = 443   # explorer, faucet, quorum list, Insight and DAPI seeds on the wallet host
    "dapi"           = 1443  # each validator's gateway
    "core-p2p"       = 20001 # Core, devnet port
    "tenderdash-p2p" = 26656
  }
}

resource "aws_vpc_security_group_ingress_rule" "devnet_public" {
  for_each = local.devnet_public_ports

  security_group_id = aws_security_group.devnet_nodes.id
  description       = each.key
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# Nodes talk to each other freely. Devnets are not separated from one
# another: they all share this group.
resource "aws_vpc_security_group_ingress_rule" "devnet_fleet" {
  security_group_id            = aws_security_group.devnet_nodes.id
  description                  = "fleet"
  referenced_security_group_id = aws_security_group.devnet_nodes.id
  ip_protocol                  = "-1"
}

# The agent, from the status host's address.
resource "aws_vpc_security_group_ingress_rule" "devnet_ssh_status_agent" {
  security_group_id = aws_security_group.devnet_nodes.id
  description       = "status-agent"
  cidr_ipv4         = "${aws_eip.status.public_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# SSH from anywhere, added by hand on 2026-10-01. It makes the rule above
# redundant. Adopted as found.
resource "aws_vpc_security_group_ingress_rule" "devnet_ssh_anywhere" {
  security_group_id = aws_security_group.devnet_nodes.id
  description       = "SSH access requested 2026-10-01"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "devnet_nodes" {
  security_group_id = aws_security_group.devnet_nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
