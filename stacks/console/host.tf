# The status host: https://status.testnet.networks.dash.org.
#
# One instance runs the console's containers (web, agent, incidents, key
# helper) behind nginx. The agent is the only thing in the estate that can
# upgrade, reset, create and destroy networks, and its SSH key is the one
# every testnet and devnet node trusts. If this host is lost nobody can
# operate the networks until it is rebuilt: see README.md, "Rebuild from
# nothing", before changing anything here.
#
# The host was built by hand on 2026-02-26 and is adopted as it runs. It has
# no first-boot script. Terraform can make the instance again; what is on its
# disk it cannot.

# --- Access -----------------------------------------------------------------

# Web traffic. SSH is not opened here: it comes from the shared group
# `testnet-ssh` (lookups.tf).
resource "aws_security_group" "status" {
  name        = "status-dashboard"
  description = "Status dashboard web access"
  vpc_id      = data.aws_vpc.testnet.id
}

resource "aws_vpc_security_group_ingress_rule" "status_web" {
  for_each = { HTTP = 80, HTTPS = 443 }

  security_group_id = aws_security_group.status.id
  description       = each.key
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_egress_rule" "status_v4" {
  security_group_id = aws_security_group.status.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "status_v6" {
  security_group_id = aws_security_group.status.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
}

# --- Host -------------------------------------------------------------------

resource "aws_instance" "status" {
  ami           = data.aws_ssm_parameter.ubuntu_2404_arm64.insecure_value
  instance_type = "t4g.medium"
  subnet_id     = data.aws_subnet.testnet_public2.id

  vpc_security_group_ids = [
    aws_security_group.status.id,
    data.aws_security_group.testnet_ssh.id,
  ]

  iam_instance_profile = aws_iam_instance_profile.status_server.name

  # The key pair of the retired testnet tooling. It only decides whose key is
  # in `ubuntu`'s authorized_keys on first boot; the keys that are there now
  # were added by hand since (README.md).
  key_name = "dn-testnet-auth"

  # No user_data: the host was set up by hand and no script of that exists.
  # README.md lists the steps.

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"

    # 2, not 1: the agent runs in a container and takes the role's
    # credentials from the metadata service, one network hop further away.
    http_put_response_hop_limit = 2
  }

  # The only disk. Everything the console keeps on the host is on it, it is
  # deleted with the instance, and nothing takes a snapshot of it. It is not
  # encrypted, and that cannot be changed on a volume that exists.
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = false
  }

  tags = { Name = "status-dashboard" }

  lifecycle {
    # Replacing this host destroys its disk, and with it the agent's SSH key,
    # the console's settings and every operation record (README.md). Remove
    # this line on purpose, never in passing.
    prevent_destroy = true

    # ami: the host was launched from Canonical's Ubuntu 24.04 image of
    # 2026-02-18 (ami-0c0be557d3f581f0e). The lookup above returns today's
    # image, which is what a new host should start from; the running one
    # cannot change the image it was launched from.
    ignore_changes = [ami]
  }
}

# --- Address ----------------------------------------------------------------

# 68.67.122.250, from the owned pool. `status.testnet.networks.dash.org`
# points at it (dns.tf) and the devnet nodes accept the agent's SSH from it
# (devnets.tf); both follow this resource. Protected because the address
# itself cannot be asked for again: a new allocation gets whichever address
# of the pool is free.
resource "aws_eip" "status" {
  domain       = "vpc"
  ipam_pool_id = data.aws_vpc_ipam_pool.owned.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip_association" "status" {
  allocation_id = aws_eip.status.id
  instance_id   = aws_instance.status.id
}
