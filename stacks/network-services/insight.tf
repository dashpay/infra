# Mainnet Insight: the host.
#
# One instance runs Dash Core and Insight in Docker (compose file
# /home/ubuntu/docker-compose.yml on the host). The load balancer in
# insight-lb.tf is the only way in. There is no SSH: use SSM Session Manager.
#
# This is a public mainnet service on a single host. The instance was built
# by hand in the old dashevo account, copied here as an image on 2026-11-20
# and adopted as it runs. Nothing below may replace or stop it as a side
# effect: see the lifecycle blocks.

locals {
  insight_tags = {
    Project = "insight"
    Network = "mainnet"
    Issue   = "dashpay/infra/19"
  }

  # The host and its data volume must be in the same zone.
  insight_zone = "us-west-2d"
}

# --- The image a new host is built from ----------------------------------

# The old host as it was on 2026-11-20 13:32 UTC: the root disk, and the
# chain data as Core had last flushed it. The image it was copied from, and
# that image's snapshots, were deleted with the old account's resources, so
# this copy and its two snapshots are the only ones.
#
# Terraform cannot make this image again (prevent_destroy). If it is ever
# replaced by a newer image of the host, change the snapshot ids here and in
# aws_ebs_volume.insight_data.
resource "aws_ami" "insight" {
  name                = "insight-mainnet-from-dashevo-20261120"
  description         = "Mainnet Insight host copied from dashevo ami-08dd6d976aba259be (dashpay/infra#19)"
  virtualization_type = "hvm"
  root_device_name    = "/dev/sda1"
  ena_support         = true

  ebs_block_device {
    device_name           = "/dev/sda1"
    snapshot_id           = "snap-0f482eefe10834fb3"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # The chain data (/mnt on the host).
  ebs_block_device {
    device_name           = "/dev/sdf"
    snapshot_id           = "snap-03b031047841d6bbf"
    volume_size           = 150
    volume_type           = "gp3"
    delete_on_termination = false
  }

  # Carried over from the original image. m7a has no instance store, so
  # these do nothing.
  ephemeral_block_device {
    device_name  = "/dev/sdb"
    virtual_name = "ephemeral0"
  }

  ephemeral_block_device {
    device_name  = "/dev/sdc"
    virtual_name = "ephemeral1"
  }

  tags = merge(local.insight_tags, { Name = "insight-mainnet" })

  lifecycle {
    prevent_destroy = true
  }
}

# --- Access ---------------------------------------------------------------

# The host's role allows SSM and nothing else.
resource "aws_iam_role" "insight" {
  name        = "insight-ssm"
  description = "Mainnet Insight host: SSM access only (dashpay/infra#19)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.insight_tags
}

resource "aws_iam_role_policy_attachment" "insight_ssm" {
  role       = aws_iam_role.insight.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "insight" {
  name = "insight-ssm"
  role = aws_iam_role.insight.name
}

# In: Insight's own port, from the load balancer only. Out: everything
# (Core's peers use many ports).
resource "aws_security_group" "insight" {
  name        = "insight-mainnet"
  description = "Mainnet Insight host: web from its load balancer only, no SSH (use SSM)"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(local.insight_tags, { Name = "insight-mainnet" })
}

resource "aws_vpc_security_group_ingress_rule" "insight_from_lb" {
  security_group_id            = aws_security_group.insight.id
  description                  = "load balancer"
  referenced_security_group_id = aws_security_group.insight_lb.id
  ip_protocol                  = "tcp"
  from_port                    = local.insight_port
  to_port                      = local.insight_port
}

resource "aws_vpc_security_group_egress_rule" "insight" {
  security_group_id = aws_security_group.insight.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Host -----------------------------------------------------------------

resource "aws_instance" "insight" {
  ami                    = aws_ami.insight.id
  instance_type          = "m7a.large"
  subnet_id              = data.aws_subnet.default[local.insight_zone].id
  vpc_security_group_ids = [aws_security_group.insight.id]
  iam_instance_profile   = aws_iam_instance_profile.insight.name

  disable_api_termination = true

  # First boot only: puts the data volume in fstab by its file system UUID,
  # mounts it at /mnt and makes Docker wait for it. The original host had
  # the volume mounted by hand; without this a copy starts Core on an empty
  # directory on the root disk.
  user_data = file("${path.module}/files/insight-user-data.yaml")

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Tagged here, not with volume_tags: that argument would claim the data
  # volume too and fight its own tags.
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
    tags        = merge(local.insight_tags, { Name = "insight-mainnet" })
  }

  # The image carries the chain data as a second disk on /dev/sdf. A new
  # host must not make its own copy of it at launch: its data volume is
  # aws_ebs_volume.insight_data, attached below on that same device.
  ephemeral_block_device {
    device_name = "/dev/sdf"
    no_device   = true
  }

  tags = merge(local.insight_tags, { Name = "insight-mainnet" })

  lifecycle {
    # Replacing this host takes a public mainnet service down for about two
    # hours (see the README). Remove this line on purpose, never in passing.
    prevent_destroy = true

    # What cannot be said about a host that already runs:
    # - ami: it was launched from the dashevo image this one is a copy of,
    #   which no longer exists;
    # - user_data: read on first boot only, and changing it stops the host;
    # - ephemeral_block_device: a launch-time instruction. The running host
    #   was launched with the image's own /dev/sdf, which is the data volume
    #   adopted below.
    ignore_changes = [ami, user_data, ephemeral_block_device]
  }
}

# --- Chain data -----------------------------------------------------------

# Core's data directory, with the address, transaction and spent indexes
# Insight reads through Core: about 112 GB in November 2026. It can always
# be had again by syncing mainnet from nothing (expect days, not measured);
# the image's snapshot restores it in hours.
resource "aws_ebs_volume" "insight_data" {
  availability_zone = local.insight_zone
  size              = 150
  type              = "gp3"
  encrypted         = true

  # A new volume starts from the image's copy of the chain data.
  snapshot_id = one([for d in aws_ami.insight.ebs_block_device : d.snapshot_id if d.device_name == "/dev/sdf"])

  tags = merge(local.insight_tags, { Name = "insight-mainnet" })

  lifecycle {
    prevent_destroy = true

    # snapshot_id: the running volume was made from the dashevo snapshot the
    # image's one is a copy of. That snapshot is gone, and a volume cannot
    # change where it came from.
    ignore_changes = [snapshot_id]
  }
}

resource "aws_volume_attachment" "insight_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.insight_data.id
  instance_id = aws_instance.insight.id
}

# --- Address --------------------------------------------------------------

# Nothing public names this address: clients come through the load
# balancer. It is what the host's own outgoing traffic comes from, and
# Core's peers see it.
resource "aws_eip" "insight" {
  domain       = "vpc"
  ipam_pool_id = data.aws_vpc_ipam_pool.owned.id

  tags = merge(local.insight_tags, { Name = "insight-mainnet" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip_association" "insight" {
  allocation_id = aws_eip.insight.id
  instance_id   = aws_instance.insight.id
}
