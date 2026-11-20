# Core's data directory, on EFS so that it outlives the host.
#
# The file system holds /dashcore: the block chain, the chain state, the
# masternode and quorum databases, and dash.conf with the RPC password. The
# host mounts it at /mnt/efs and links /home/dash/.dashcore to it.
#
# All of it except dash.conf can be had again by syncing the network from
# nothing. Nothing backs it up. Where efs_replica_region is set, EFS keeps a
# copy in that region (below).
resource "aws_efs_file_system" "core" {
  region         = var.region
  creation_token = "${var.network}-dash-core-efs"
  encrypted      = true

  # Files not read for 30 days move to the cheaper storage class. That is
  # most of an old chain.
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(local.tags, { Name = "${var.network}-dash-core-efs" })

  lifecycle {
    # Losing this means a resync from nothing and a new RPC password.
    prevent_destroy = true
  }
}

resource "aws_efs_mount_target" "core" {
  for_each = var.efs_subnet_ids

  region          = var.region
  file_system_id  = aws_efs_file_system.core.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# A copy of the file system in another region, kept current by EFS itself.
# EFS makes the destination file system and owns it while it replicates: it
# is read-only and is not a resource here.
resource "aws_efs_replication_configuration" "core" {
  count = var.efs_replica_region == null ? 0 : 1

  region                = var.region
  source_file_system_id = aws_efs_file_system.core.id

  destination {
    region = var.efs_replica_region
  }
}

# In: NFS from the Core backend only.
resource "aws_security_group" "efs" {
  region      = var.region
  name        = "${var.network}-efs-sg"
  description = "Security group for EFS mount targets"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.network}-efs-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  region                       = var.region
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_vpc_security_group_egress_rule" "efs" {
  region            = var.region
  security_group_id = aws_security_group.efs.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
