# Adoption of what was built by script on 2026-11-20 (dashpay/infra#19).
# Inert once applied. To build this stack from nothing, delete this file.

# --- Host backups ---

import {
  to = aws_s3_bucket.backups
  id = "dash-backups-854439639386-usw2"
}

import {
  to = aws_s3_bucket_versioning.backups
  id = "dash-backups-854439639386-usw2"
}

import {
  to = aws_s3_bucket_lifecycle_configuration.backups
  id = "dash-backups-854439639386-usw2"
}

import {
  to = aws_iam_user.backup["wp2021"]
  id = "backup-wp2021"
}

import {
  to = aws_iam_user.backup["forum2023"]
  id = "backup-forum2023"
}

import {
  to = aws_iam_user_policy.backup["wp2021"]
  id = "backup-wp2021:backup-own-prefix"
}

import {
  to = aws_iam_user_policy.backup["forum2023"]
  id = "backup-forum2023:backup-own-prefix"
}

# --- Archive of the dashevo account ---

import {
  to = aws_s3_bucket.archive
  id = "dash-dashevo-archive-854439639386-usw2"
}

import {
  to = aws_s3_bucket_policy.archive
  id = "dash-dashevo-archive-854439639386-usw2"
}

# --- What both buckets share ---

import {
  to = aws_s3_bucket_public_access_block.private["backups"]
  id = "dash-backups-854439639386-usw2"
}

import {
  to = aws_s3_bucket_public_access_block.private["archive"]
  id = "dash-dashevo-archive-854439639386-usw2"
}

import {
  to = aws_s3_bucket_ownership_controls.private["backups"]
  id = "dash-backups-854439639386-usw2"
}

import {
  to = aws_s3_bucket_ownership_controls.private["archive"]
  id = "dash-dashevo-archive-854439639386-usw2"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.private["backups"]
  id = "dash-backups-854439639386-usw2"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.private["archive"]
  id = "dash-dashevo-archive-854439639386-usw2"
}

# --- Kept snapshot ---

import {
  to = aws_ebs_snapshot.dashevo_unattached_volume
  id = "snap-04da04a6a2a0c072d"
}
