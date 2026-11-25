# A snapshot kept on purpose.
#
# The old dashevo account had an unattached, untagged 50 GB volume
# (vol-034a799f82afd22a7, created 2024-05-07) that nobody could identify.
# This is a copy of it, taken on 2026-11-20 before the volume was deleted.
# What is on it is not known. It is here so that it is not mistaken for an
# orphan and removed.
#
# Terraform cannot make it again: the volume is gone. `volume_id` is what
# AWS reports for a snapshot that was copied from another one. To build
# this stack from nothing, leave this file out.

resource "aws_ebs_snapshot" "dashevo_unattached_volume" {
  volume_id   = "vol-ffffffff"
  description = "Copy of dashevo's unattached, untagged 50 GB volume vol-034a799f82afd22a7 (created 2024-05-07). Contents unknown. dashpay/infra#19"

  tags = {
    Name  = "dashevo-unattached-volume-20240507"
    Issue = "dashpay/infra/19"
  }

  lifecycle {
    prevent_destroy = true
  }
}
