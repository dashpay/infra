# The quorum server: dashpay/quorum-list-server, one binary under systemd.
# It keeps nothing but its configuration and its log. Everything it serves
# is read from Core and held in memory.

# In: its port from the load balancer, SSH from the bastion.
resource "aws_security_group" "quorum_server" {
  region      = var.region
  name        = "${var.network}-quorum-server-sg"
  description = "Security group for Quorum server"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.network}-quorum-server-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "quorum_server_http" {
  region                       = var.region
  security_group_id            = aws_security_group.quorum_server.id
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.quorum_server_port
  to_port                      = local.quorum_server_port
}

resource "aws_vpc_security_group_ingress_rule" "quorum_server_ssh" {
  region                       = var.region
  security_group_id            = aws_security_group.quorum_server.id
  referenced_security_group_id = var.bastion_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "quorum_server" {
  region            = var.region
  security_group_id = aws_security_group.quorum_server.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "quorum_server" {
  region                 = var.region
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = var.host_subnet_id
  vpc_security_group_ids = [aws_security_group.quorum_server.id]

  # First boot only: installs the server and writes its configuration,
  # without the RPC password. The file says what is left to do by hand.
  user_data = templatefile("${path.module}/files/quorum-server-first-boot.sh.tftpl", {
    network     = var.network
    version     = var.quorum_server_version
    listen_port = local.quorum_server_port
    core_ip     = aws_instance.core.private_ip
    core_port   = local.core_rpc_port
  })

  # As found: the instance metadata service still answers version 1
  # requests.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  # The server's log is on this disk and is not rotated. It filled the
  # mainnet host's disk on 2026-10-30.
  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  tags = merge(local.tags, { Name = "${var.network}-quorum-server" })

  lifecycle {
    # Remove this line on purpose, never in passing.
    prevent_destroy = true

    # What cannot be said about a host that already runs:
    # - ami: it was launched from the Ubuntu 22.04 image of June 2025;
    # - user_data: read at first boot only. The host was launched with an
    #   older script, and changing it would stop the instance.
    ignore_changes = [ami, user_data]
  }
}
