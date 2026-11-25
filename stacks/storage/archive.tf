# The archive of the old dashevo account (103738324493).
#
# Copies of that account's leftover buckets, taken on 2026-11-20 before they
# were emptied: <old bucket name>/<key>, current versions only, stored as
# Glacier Instant Retrieval. It holds dashevo-infra (mostly CloudFront logs
# up to 2020 and AWS Config history), the three Terraform state buckets,
# old copies of static sites and a 2025 WordPress dump.
#
# The old Terraform state files in it may contain secrets. Keep the bucket
# private.
#
# Nothing writes here any more. It is the only copy of what the old account
# held, so it cannot be made again.

resource "aws_s3_bucket" "archive" {
  bucket = "dash-dashevo-archive-854439639386-usw2"

  tags = {
    Project = "dashevo-archive"
    Issue   = "dashpay/infra/19"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# How the archive was filled: the copy ran as dashevo's user `daniel`, who
# could read the old buckets, and this lets that user write here. Objects
# belong to this account whoever writes them (private-buckets.tf).
#
# It is still in place so the copy can be repeated for dashevo-infra, the
# one source bucket that still exists. The bucket has no versioning, so
# this permission can also overwrite what is archived: remove the policy
# when the old account is closed or the last source bucket is gone.
resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DashevoWritesTheArchive"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::103738324493:user/daniel" }
      Action    = ["s3:PutObject", "s3:ListBucket"]
      Resource  = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
    }]
  })
}

output "archive" {
  description = "The archive of the old dashevo account."
  value       = aws_s3_bucket.archive.bucket
}
