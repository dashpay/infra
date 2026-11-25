# What both buckets in this stack have in common: nothing in them is public,
# every object belongs to this account, and everything is encrypted at rest.

locals {
  private_buckets = {
    backups = aws_s3_bucket.backups.id
    archive = aws_s3_bucket.archive.id
  }
}

resource "aws_s3_bucket_public_access_block" "private" {
  for_each = local.private_buckets

  bucket = each.value

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ACLs are off. An object is owned by this account whoever uploads it, which
# matters for the archive: its objects were written by a user of another
# account.
resource "aws_s3_bucket_ownership_controls" "private" {
  for_each = local.private_buckets

  bucket = each.value

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# S3's own keys. This is what S3 gives every new bucket; it is written down
# so that a change to it shows up in a plan.
resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  for_each = local.private_buckets

  bucket = each.value

  rule {
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
