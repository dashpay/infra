# chat.dash.org: a redirect to the Dash Discord invite.
#
# Older than the rest of this stack and made by hand. An empty bucket set up
# as a website answers every request with a redirect; CloudFront in front of
# it adds https. The host name is in the Cloudflare zone dash.org, which
# Terraform does not manage: the output `dns_by_hand` lists the records to
# keep there.

# The name must stay the host name: the bucket's website address is derived
# from it. It holds no objects, only the redirect rule below.
resource "aws_s3_bucket" "chat" {
  region = "us-east-1"

  bucket = "chat.dash.org"
}

resource "aws_s3_bucket_website_configuration" "chat" {
  region = "us-east-1"

  bucket = aws_s3_bucket.chat.id

  index_document {
    suffix = "index.html"
  }

  # To change where chat.dash.org leads, change the invite here.
  routing_rule {
    redirect {
      protocol           = "https"
      host_name          = "discord.com"
      replace_key_with   = "invite/PXbUxJB"
      http_redirect_code = "301"
    }
  }
}

# A website endpoint only answers for a publicly readable bucket, so the
# public access block is off and the policy lets anyone read. There is
# nothing in the bucket to read.
resource "aws_s3_bucket_public_access_block" "chat" {
  region = "us-east-1"

  bucket = aws_s3_bucket.chat.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "chat" {
  region = "us-east-1"

  bucket = aws_s3_bucket.chat.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.chat.arn}/*"
    }]
  })

  # A public policy is refused while the public access block is on.
  depends_on = [aws_s3_bucket_public_access_block.chat]
}

# CloudFront only takes certificates from us-east-1. ACM renews this one for
# as long as its validation record exists at Cloudflare.
resource "aws_acm_certificate" "chat" {
  region = "us-east-1"

  domain_name       = "chat.dash.org"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_distribution" "chat" {
  comment         = "Redirect chat.dash.org to Discord invite"
  enabled         = true
  aliases         = ["chat.dash.org"]
  http_version    = "http2"
  is_ipv6_enabled = true
  price_class     = "PriceClass_100"

  # A bucket's website endpoint speaks plain http only.
  origin {
    origin_id   = "S3-Website-chat.dash.org"
    domain_name = aws_s3_bucket_website_configuration.chat.website_endpoint

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  # The old way of setting cache lifetimes (no cache policy), as the
  # distribution was made.
  default_cache_behavior {
    target_origin_id       = "S3-Website-chat.dash.org"
    viewer_protocol_policy = "allow-all"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.chat.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}
