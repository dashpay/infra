# The Core backend: a full node with no wallet and no masternode key. The
# quorum server asks it for quorum and masternode lists over RPC.

# In: P2P from anywhere, RPC from the quorum server, SSH from the bastion.
resource "aws_security_group" "core" {
  region      = var.region
  name        = "${var.network}-dash-core-sg"
  description = "Security group for Dash Core node"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.network}-dash-core-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "core_p2p" {
  region            = var.region
  security_group_id = aws_security_group.core.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = local.core_p2p_port
  to_port           = local.core_p2p_port
}

resource "aws_vpc_security_group_ingress_rule" "core_rpc" {
  region                       = var.region
  security_group_id            = aws_security_group.core.id
  referenced_security_group_id = aws_security_group.quorum_server.id
  ip_protocol                  = "tcp"
  from_port                    = local.core_rpc_port
  to_port                      = local.core_rpc_port
}

resource "aws_vpc_security_group_ingress_rule" "core_rpc_cidr" {
  for_each = toset(var.core_rpc_extra_cidrs)

  region            = var.region
  security_group_id = aws_security_group.core.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = local.core_rpc_port
  to_port           = local.core_rpc_port
}

resource "aws_vpc_security_group_ingress_rule" "core_ssh" {
  region                       = var.region
  security_group_id            = aws_security_group.core.id
  referenced_security_group_id = var.bastion_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "core" {
  region            = var.region
  security_group_id = aws_security_group.core.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "core" {
  region                 = var.region
  ami                    = var.ami_id
  instance_type          = "t3.medium"
  key_name               = var.key_name
  subnet_id              = var.host_subnet_id
  private_ip             = var.core_private_ip
  vpc_security_group_ids = [aws_security_group.core.id]

  # First boot only: installs Core, mounts the file system and starts dashd.
  # The file says what it does and does not set up.
  user_data = templatefile("${path.module}/files/core-first-boot.sh.tftpl", {
    network      = var.network
    core_version = var.core_version
    efs_dns_name = aws_efs_file_system.core.dns_name
    p2p_port     = local.core_p2p_port
    rpc_port     = local.core_rpc_port
    rpc_allow_ip = var.vpc_cidr
    conf_extra   = var.core_conf_extra
  })

  # As found: the instance metadata service still answers version 1
  # requests.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  # The system disk. Core's data is not on it (see efs.tf).
  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${var.network}-dash-core" })

  # A new host mounts the file system at first boot, so the mount targets
  # must exist before it starts.
  depends_on = [aws_efs_mount_target.core]

  lifecycle {
    # The quorum service is down while its backend is. Remove this line on
    # purpose, never in passing.
    prevent_destroy = true

    # What cannot be said about a host that already runs:
    # - ami: it was launched from the Ubuntu 22.04 image of June 2025;
    # - user_data: read at first boot only. The host was launched with an
    #   older script, and changing it would stop the instance.
    ignore_changes = [ami, user_data]
  }
}
