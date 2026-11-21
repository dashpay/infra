# Daily copies of the database, written by the host with VACUUM INTO.
#
# A backup still holds what a person's opt-out or account deletion removed
# from the live database, so the expiry rule below is part of the service's
# privacy promise, not housekeeping. Versioning stays off for the same
# reason: an expired object must be gone.

resource "aws_s3_bucket" "backup" {
  bucket = "${var.name}-backups-${local.account_id}"

  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-backups"
    status = "Enabled"

    # Backups only. The bucket also holds volumes/, the record of which
    # data volumes have been formatted, and that must never expire.
    filter {
      prefix = "daily/"
    }

    expiration {
      days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
