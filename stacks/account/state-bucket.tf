# The bucket that holds every stack's Terraform state, this stack's included.
#
# It was made by hand and is adopted here with exactly the settings it has:
# versioned, encrypted with S3's own keys, closed to the public. It has no
# bucket policy and no lifecycle rule, so old state versions are kept for
# ever; that is deliberate here (state objects are small, and an old version
# is how a damaged state is put back).
#
# Losing this bucket loses the record of what Terraform owns. Nothing in AWS
# stops working, but every stack then has to be imported again.

locals {
  state_bucket_region = "us-east-1"
}

resource "aws_s3_bucket" "state" {
  region = local.state_bucket_region
  bucket = "dash-terraform-state-854439639386"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  region = local.state_bucket_region
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  region = local.state_bucket_region
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    # Uploads encrypted with a key only the uploader holds are refused, so a
    # state object can always be read back by whoever may read the bucket.
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  region = local.state_bucket_region
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# No ACLs: every object belongs to the account.
resource "aws_s3_bucket_ownership_controls" "state" {
  region = local.state_bucket_region
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

output "state_bucket" {
  description = "Bucket and region every stack's backend block names."
  value       = "${aws_s3_bucket.state.bucket} (${local.state_bucket_region})"
}
