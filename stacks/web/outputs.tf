output "sites" {
  description = "What each site's repository keeps in its Actions secrets: AWS_ROLE_TO_ASSUME, AWS_REGION, S3_BUCKET, S3_PREFIX, CLOUDFRONT_DISTRIBUTION_ID."
  value = {
    for key, site in module.site : key => {
      hostname                   = local.sites[key].hostname
      deploys_from               = local.sites[key].deploys_from
      AWS_ROLE_TO_ASSUME         = site.deploy_role_arn
      AWS_REGION                 = aws_s3_bucket.sites.region
      S3_BUCKET                  = aws_s3_bucket.sites.bucket
      S3_PREFIX                  = key
      CLOUDFRONT_DISTRIBUTION_ID = site.distribution_id
    }
  }
}

locals {
  # Host names in the Cloudflare zone dash.org: where each one points, and
  # the record that keeps its certificate valid.
  at_cloudflare = merge(
    {
      for key, site in module.site : local.sites[key].hostname => {
        target     = site.distribution_domain_name
        validation = site.certificate_validation
      } if local.sites[key].zone == null
    },
    {
      "media.dash.org" = {
        target     = aws_cloudfront_distribution.media.domain_name
        validation = one(aws_acm_certificate.media.domain_validation_options)
      }
      "chat.dash.org" = {
        target     = aws_cloudfront_distribution.chat.domain_name
        validation = one(aws_acm_certificate.chat.domain_validation_options)
      }
    },
  )
}

output "dns_by_hand" {
  description = "Records to keep in the Cloudflare zone dash.org, which Terraform does not manage. Both are CNAMEs and must not be proxied: the host name itself, and the name ACM checks to issue and renew the certificate."
  value = {
    for hostname, site in local.at_cloudflare : hostname => {
      (hostname)                             = site.target
      (site.validation.resource_record_name) = site.validation.resource_record_value
    }
  }
}

output "openai_proxy_url" {
  description = "The URL dashpay.io posts to. It is written into the site's source (src/services/openai.rs in dashpay/data-contract-creator)."
  value       = aws_lambda_function_url.openai_proxy.function_url
}
