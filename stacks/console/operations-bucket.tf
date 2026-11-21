# dash-status-operations-854439639386-usw2: where the console and the
# "Reviewed console operation" workflow exchange a request and its result
# (operations-roles.tf):
#
#   managed/<network>/requests/<request id>/   input.json, the dashnet
#                                              binary, known_hosts
#   managed/<network>/results/<request id>/    inventory, log, receipt
#
# It holds 12 objects (42 MB), all written on 2026-09-28 when that path was
# set up, for testnet and for Moutai. Nothing has written to it since, and
# the status host's role has no S3 permission on it. Nothing expires.

resource "aws_s3_bucket" "operations" {
  bucket = "dash-status-operations-854439639386-usw2"


  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "operations" {
  bucket = aws_s3_bucket.operations.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "operations" {
  bucket = aws_s3_bucket.operations.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "operations" {
  bucket = aws_s3_bucket.operations.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "operations" {
  bucket = aws_s3_bucket.operations.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# TLS only.
resource "aws_s3_bucket_policy" "operations" {
  bucket = aws_s3_bucket.operations.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.operations.arn, "${aws_s3_bucket.operations.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
