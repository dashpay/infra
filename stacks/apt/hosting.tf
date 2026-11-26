# https://apt.services.dash.org/dashmate: a private bucket behind CloudFront.
#
# The bucket holds the repository as apt reads it, under the prefix
# `dashmate/`. Nothing is public but through the distribution, and the
# distribution can read that prefix only.

resource "aws_s3_bucket" "repository" {
  bucket = "dash-apt-repository-${local.account}"

  # The pool is what makes `apt install dashmate=<old>` work. It cannot be
  # made again once the GitHub releases it came from are gone.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "repository" {
  bucket = aws_s3_bucket.repository.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "repository" {
  bucket = aws_s3_bucket.repository.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "repository" {
  bucket = aws_s3_bucket.repository.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Release, InRelease and the indexes are rewritten every day. Their old
# versions are kept for 90 days, long enough to see what a host was served.
# The pool is written once and has no old versions.
resource "aws_s3_bucket_lifecycle_configuration" "repository" {
  bucket = aws_s3_bucket.repository.id

  rule {
    id     = "expire-old-index-versions"
    status = "Enabled"

    filter {
      prefix = "${local.prefix}/dists/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.repository]
}

resource "aws_cloudfront_origin_access_control" "repository" {
  name                              = "dash-apt-repository"
  description                       = "CloudFront reads the dashmate apt repository's bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "repository_bucket" {
  statement {
    sid       = "CloudFrontReadsTheRepository"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.repository.arn}/${local.prefix}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.repository.arn]
    }
  }

  # With this, a file that does not exist is a 404. Without it S3 answers
  # 403, which apt reports as an error where it would pass over a 404.
  # CloudFront never lists the bucket for a viewer.
  statement {
    sid       = "MissingFilesAre404"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.repository.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.repository.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "repository" {
  bucket = aws_s3_bucket.repository.id
  policy = data.aws_iam_policy_document.repository_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.repository]
}

data "aws_route53_zone" "services" {
  name = "services.dash.org"
}

# CloudFront only takes certificates from us-east-1.
resource "aws_acm_certificate" "repository" {
  region = "us-east-1"

  domain_name       = local.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM renews the certificate for as long as this record exists.
resource "aws_route53_record" "certificate_validation" {
  zone_id = data.aws_route53_zone.services.zone_id
  name    = one(aws_acm_certificate.repository.domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.repository.domain_validation_options).resource_record_type
  ttl     = 300
  records = [one(aws_acm_certificate.repository.domain_validation_options).resource_record_value]
}

resource "aws_acm_certificate_validation" "repository" {
  region = "us-east-1"

  certificate_arn         = aws_acm_certificate.repository.arn
  validation_record_fqdns = [aws_route53_record.certificate_validation.fqdn]
}

# The publisher sets Cache-Control on everything it writes: a minute on
# Release, InRelease and the index names, a year on the pool and on by-hash
# paths, whose content never changes. This policy honours those.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_response_headers_policy" "repository" {
  name    = "dash-apt-repository"
  comment = "HSTS for the dashmate apt repository"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      override                   = true
    }

    content_type_options {
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "repository" {
  comment         = "dashmate apt repository (dashpay/platform#4246)"
  enabled         = true
  aliases         = [local.hostname]
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"

  origin {
    origin_id                = "repository"
    domain_name              = aws_s3_bucket.repository.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.repository.id
  }

  default_cache_behavior {
    target_origin_id           = "repository"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.repository.id

    # apt checks every byte against a hash. Nothing is re-encoded on the way.
    compress = false
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.repository.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_route53_record" "repository" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.services.zone_id
  name    = local.hostname
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.repository.domain_name
    zone_id                = aws_cloudfront_distribution.repository.hosted_zone_id
    evaluate_target_health = false
  }
}
