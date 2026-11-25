# media.dash.org: the dash.org WordPress media library.
#
# WordPress on wp2021 (plugin WP Offload Media) uploads into the bucket as
# the IAM user below; visitors read through CloudFront. The host name is in
# the Cloudflare zone dash.org, which Terraform does not manage: the output
# `dns_by_hand` lists the records to keep there.

locals {
  media_tags = {
    Project = "website-media"
    Issue   = "dashpay/infra/19"
  }
}

# The only copy of the media library. Versioning keeps what WordPress
# overwrites or deletes.
resource "aws_s3_bucket" "media" {
  bucket = "dash-media-854439639386-usw2"

  tags = local.media_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id

  versioning_configuration {
    status = "Enabled"
  }
}

# The plugin sets an ACL on every upload, so ACLs stay enabled and are
# accepted (block_public_acls is off), but a public ACL is ignored: nothing
# in the bucket is readable except through CloudFront.
resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = false
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Any CloudFront distribution of this account may read, as with the sites'
# bucket.
resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontReadFromThisAccount"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.media.arn}/*"
      Condition = { ArnLike = { "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*" } }
    }]
  })
}

# CloudFront only takes certificates from us-east-1. ACM renews this one for
# as long as its validation record exists at Cloudflare.
resource "aws_acm_certificate" "media" {
  region = "us-east-1"

  domain_name       = "media.dash.org"
  validation_method = "DNS"

  # Tagged as a static site, like the distribution: the same tool made both.
  tags = local.site_tags

  lifecycle {
    create_before_destroy = true
  }
}

# The same shape as a static site, with three differences: its own bucket,
# served from the bucket's root, and plain http is answered rather than
# redirected to https, as the old distribution did.
resource "aws_cloudfront_distribution" "media" {
  comment         = "static-site:media media.dash.org (moved from dashevo, dashpay/infra#19)"
  enabled         = true
  aliases         = ["media.dash.org"]
  http_version    = "http2"
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.media.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.sites.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "allow-all"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.media.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = local.site_tags
}

# AWS's own policy: cache by path only, compress, long lifetimes.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# The user WordPress uploads as. Its access key is not managed here, so that
# the secret never reaches Terraform's state: the key lives only in the
# WordPress option `tantan_wordpress_s3` on wp2021. To rotate it, make a new
# key by hand, put it in that option, then delete the old one.
resource "aws_iam_user" "wordpress_media" {
  name = "wordpress-media"

  tags = local.media_tags
}

resource "aws_iam_user_policy" "wordpress_media" {
  name = "media-bucket"
  user = aws_iam_user.wordpress_media.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.media.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObjectAcl",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.media.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListAllMyBuckets"
        Resource = "*"
      },
    ]
  })
}
