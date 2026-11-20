# The host that serves the mainnet quorum list today.
#
# On 2026-10-05 there was no working login to mainnet-quorum-server, which
# is in a private subnet. An image of it was launched as this host in a
# public subnet, with latte's SSH key put in by cloud-init. The server on it
# was then updated by hand to 0.7.0, and the target group was switched to
# it. The original still runs, registered nowhere, as the way back.
#
# It is a one-off beside module.mainnet, not part of the shape: it uses the
# module's quorum server security group (so the load balancer and Core let
# it in) plus an SSH group of its own. The tidy end state is one mainnet
# quorum server again. Getting there is a cutover, not a Terraform edit.

# SSH from one address: the public address the earlier operations agent's
# host had on 2026-10-05.
resource "aws_security_group" "mainnet_quorum_recovery_ssh" {
  region      = local.region
  name        = "mainnet-quorum-recovery-ssh-20261005"
  description = "Owner-authorized SSH access to mainnet quorum replacement only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "mainnet-quorum-recovery-ssh-20261005"
    Environment = "mainnet"
  }
}

resource "aws_vpc_security_group_ingress_rule" "mainnet_quorum_recovery_ssh" {
  region            = local.region
  security_group_id = aws_security_group.mainnet_quorum_recovery_ssh.id
  description       = "Owner-authorized Infraclaw SSH source 2026-10-05"
  cidr_ipv4         = "153.67.85.166/32"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "mainnet_quorum_recovery_ssh" {
  region            = local.region
  security_group_id = aws_security_group.mainnet_quorum_recovery_ssh.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "mainnet_quorum_recovery" {
  region = local.region

  # The image taken of mainnet-quorum-server on 2026-10-05
  # (mainnet-quorum-access-recovery-20261005), owned by this account. It
  # holds the server as it was before the update to 0.7.0. On this host that
  # old binary answered /health but returned no quorums, so another host
  # launched from the image must be checked on /quorums before it serves:
  # see the README.
  ami = "ami-01e626ed8a026c719"

  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public["1"].id

  # No key pair: the image's authorized_keys and the first-boot file below
  # are the only way in.
  vpc_security_group_ids = [
    aws_security_group.mainnet_quorum_recovery_ssh.id,
    module.mainnet.quorum_server_security_group_id,
  ]

  # First boot only: turns password login off, makes new host keys and adds
  # latte's public key for the ubuntu user.
  user_data = file("${path.module}/files/mainnet-quorum-recovery-user-data.yaml")

  # As found: the instance metadata service still answers version 1
  # requests.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  # The server's log is on this disk and is not rotated. It filled the disk
  # on 2026-10-30.
  root_block_device {
    volume_type = "gp2"
    volume_size = 8

    tags = {
      Name        = "mainnet-quorum-server-recovery-20261005"
      Environment = "mainnet"
    }
  }

  tags = {
    Name           = "mainnet-quorum-server-recovery-20261005"
    Environment    = "mainnet"
    SourceInstance = "i-094434fbc0847aac7"
  }

  lifecycle {
    # This is the mainnet quorum list. Remove this line on purpose, never in
    # passing.
    prevent_destroy = true

    # user_data: read at first boot only, and changing it would stop the
    # instance. The host was launched with a longer file that also carried a
    # temporary key, which has since expired and been removed from the host.
    ignore_changes = [user_data]
  }
}
