# Host backups: where the website and forum hosts put their dumps.
#
# wp2021 (the WordPress behind dash.org) and forum2023 (the forum) are not
# AWS hosts. Each runs cron scripts in /root/ that upload database dumps and
# copies of the site's files under cowboy/<host>/ in this bucket, with the
# access key of its own IAM user below.
#
# The bucket also holds the whole history of the old account's
# dashevo-backups bucket, copied here on 2026-11-20: 1.67 million object
# versions, about 4.2 TB, from some thirty past and present hosts.
#
# Nothing here expires and nothing can be made again. The backups include
# each host's /root, with its .ssh and .aws directories: treat everything in
# the bucket as secret.

locals {
  backups_tags = {
    Project = "backups"
    Issue   = "dashpay/infra/19"
  }

  # Hosts that write backups. Each gets a user that can touch only its own
  # prefix, cowboy/<host>/.
  backup_hosts = toset(["wp2021", "forum2023"])
}

resource "aws_s3_bucket" "backups" {
  bucket = "dash-backups-854439639386-usw2"

  tags = local.backups_tags

  lifecycle {
    prevent_destroy = true
  }
}

# A host's key cannot delete (see the users below), but it can overwrite.
# With versioning an overwritten backup is still there as an older version.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Backups are written once and almost never read. After 30 days they move to
# Glacier Instant Retrieval: the same immediate access at about a sixth of
# the storage price, with a charge per GB read. No rule deletes anything.
# The rule has no filter: it covers every object.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "to-glacier-instant-after-30-days"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER_IR"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- The hosts' users -------------------------------------------------------

# The user and its policy only. Its access key is made by hand and lives in
# /root/.aws/credentials on the host and nowhere else (README).
resource "aws_iam_user" "backup" {
  for_each = local.backup_hosts

  name = "backup-${each.key}"

  tags = merge(local.backups_tags, { Host = each.key })
}

# A host may list the bucket, and read and write under its own prefix. It
# may never delete, whatever else it is given: a host that is broken into
# cannot remove its own backups, only add to them.
resource "aws_iam_user_policy" "backup" {
  for_each = local.backup_hosts

  name = "backup-own-prefix"
  user = aws_iam_user.backup[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "List"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Sid      = "ReadWriteOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${aws_s3_bucket.backups.arn}/cowboy/${each.key}/*"
      },
      {
        Sid      = "NeverDelete"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
    ]
  })
}

output "backups" {
  description = "Where each host writes its backups, and as which user."
  value = {
    bucket = aws_s3_bucket.backups.bucket
    hosts = {
      for host in local.backup_hosts : host => {
        user   = aws_iam_user.backup[host].name
        prefix = "cowboy/${host}/"
      }
    }
  }
}
