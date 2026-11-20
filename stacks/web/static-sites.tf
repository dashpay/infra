# The static sites moved from the dashevo account on 2026-11-20
# (dashpay/infra#19).
#
# One private bucket holds them all, one prefix per site. CloudFront reads
# it through an origin access control; nothing else can. Each site has its
# own distribution, certificate and, where a repository publishes it, a
# deploy role: modules/web-static-site.

locals {
  # zone: the Route 53 zone that holds the host name. Null means the name is
  #   in the Cloudflare zone dash.org, which Terraform does not manage: the
  #   module then makes the certificate and the distribution only, and the
  #   output `dns_by_hand` lists the records to keep at Cloudflare.
  # deploys_from: the repository whose workflow publishes the site.
  sites = {
    grovedb   = { hostname = "www.grovedb.org", zone = "grovedb.org", deploys_from = "dcginfra/grovedb-site" }
    dashmate  = { hostname = "www.dashmate.org", zone = "dashmate.org", deploys_from = "dcginfra/dashmate-site" }
    dashpayio = { hostname = "dashpay.io", zone = "dashpay.io", deploys_from = "dashpay/data-contract-creator" }
    proposal  = { hostname = "proposal.dash.org", zone = null, deploys_from = "dashpay/proposal-generator" }

    # Two files, uploaded by hand. No repository deploys this site.
    paper = { hostname = "paper.dash.org", zone = null, deploys_from = null }
  }

  # proposal.dash.org also answers OPTIONS, as its old distribution did.
  site_methods = {
    proposal = ["GET", "HEAD", "OPTIONS"]
  }

  # The proposal role's description still names the repository's old home,
  # dashevo/proposal-generator, which now only redirects. Kept so that
  # adopting the role changes nothing. Remove the entry to correct it.
  site_deploy_role_descriptions = {
    proposal = "GitHub Actions deploy of proposal.dash.org from dashevo/proposal-generator (dashpay/infra#19)"
  }

  site_tags = {
    Project = "static-sites"
    Issue   = "dashpay/infra/19"
  }
}

# The GitHub Actions OIDC provider belongs to the `account` stack.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

module "site" {
  source   = "../../modules/web-static-site"
  for_each = local.sites

  key       = each.key
  hostname  = each.value.hostname
  zone_name = each.value.zone
  comment   = "static-site:${each.key} ${each.value.hostname} (moved from dashevo, dashpay/infra#19)"

  bucket                   = aws_s3_bucket.sites
  origin_access_control_id = aws_cloudfront_origin_access_control.sites.id
  allowed_methods          = lookup(local.site_methods, each.key, ["GET", "HEAD"])

  deploy_repository        = each.value.deploys_from
  deploy_role_description  = lookup(local.site_deploy_role_descriptions, each.key, null)
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  tags = local.site_tags
}

# Site content can be published again from the repositories, except
# paper.dash.org's two files, which no repository holds (README.md says
# where a copy is). Versioning keeps what a deploy overwrites or deletes.
resource "aws_s3_bucket" "sites" {
  bucket = "dash-static-sites-854439639386-usw2"

  tags = local.site_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "sites" {
  bucket = aws_s3_bucket.sites.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ACLs stay enabled because the sites' workflows upload with `--acl private`,
# which a bucket with ACLs disabled refuses. The public access block below
# makes sure no ACL can ever open an object.
resource "aws_s3_bucket_ownership_controls" "sites" {
  bucket = aws_s3_bucket.sites.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "sites" {
  bucket = aws_s3_bucket.sites.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

# Any CloudFront distribution of this account may read, not only the sites'
# own: that is how the bucket was set up on 2026-11-20. Each distribution
# still only reaches the prefix its origin path names.
resource "aws_s3_bucket_policy" "sites" {
  bucket = aws_s3_bucket.sites.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontReadFromThisAccount"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.sites.arn}/*"
      Condition = { ArnLike = { "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*" } }
    }]
  })
}

# Also used by the media.dash.org distribution (media.tf).
resource "aws_cloudfront_origin_access_control" "sites" {
  name                              = "dash-static-sites"
  description                       = "CloudFront read access to dash-static-sites-854439639386-usw2"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
