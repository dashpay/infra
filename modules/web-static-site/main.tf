# One static site: a certificate, a CloudFront distribution that serves one
# prefix of the shared bucket, the site's DNS records where the zone is in
# Route 53, and (deploy.tf) the role its repository publishes with.

locals {
  in_route53 = var.zone_name != null

  # CloudFront looked for this TXT record when the host name was moved to
  # this distribution from another account (UpdateDomainAssociation). The
  # name is `_<host>`, or `_.<host>` when the host is the zone itself.
  proof_name = var.hostname == var.zone_name ? "_.${var.hostname}" : "_${var.hostname}"

  validation = one(aws_acm_certificate.this.domain_validation_options)
}

# CloudFront only takes certificates from us-east-1.
resource "aws_acm_certificate" "this" {
  region = "us-east-1"

  domain_name       = var.hostname
  validation_method = "DNS"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# AWS's own policy: cache by path only, compress, long lifetimes. A deploy
# invalidates the distribution.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "this" {
  comment             = var.comment
  enabled             = true
  aliases             = [var.hostname]
  default_root_object = "index.html"
  http_version        = "http2"
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"

  origin {
    origin_id                = "s3-site"
    domain_name              = var.bucket.bucket_regional_domain_name
    origin_path              = "/${var.key}"
    origin_access_control_id = var.origin_access_control_id
  }

  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = var.allowed_methods
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.this.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = var.tags
}

data "aws_route53_zone" "this" {
  count = local.in_route53 ? 1 : 0

  name = var.zone_name
}

resource "aws_route53_record" "alias" {
  for_each = local.in_route53 ? toset(["A", "AAAA"]) : []

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.hostname
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# ACM renews the certificate for as long as this record exists.
resource "aws_route53_record" "validation" {
  count = local.in_route53 ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = local.validation.resource_record_name
  type    = local.validation.resource_record_type
  ttl     = 300
  records = [local.validation.resource_record_value]
}

resource "aws_route53_record" "proof" {
  count = local.in_route53 ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = local.proof_name
  type    = "TXT"
  ttl     = 300
  records = [aws_cloudfront_distribution.this.domain_name]
}
