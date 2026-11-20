# Two certificates for the same five names. Both are in use, so both are
# kept as found:
#
# - "cdn" (tagged testnet-cert, July 2025) was the load balancer's. Since
#   September 2026 the two CloudFront distributions use it.
# - "alb" was made by hand on 2026-07-30 as an emergency replacement and is
#   the one on the load balancer's listener.
#
# ACM renews both by itself as long as the validation records below exist.
# One of the two would do for everything; merging them means changing the
# listener or the distributions, which is not done here.
#
# faucet.testnet is on the certificates because the testnet faucet is served
# by the same load balancer (see the README). Its validation record is here
# for that reason, though the faucet itself is not.

locals {
  certificate_names = [
    "*.networks.dash.org",
    "quorums.testnet.networks.dash.org",
    "quorums.mainnet.networks.dash.org",
    "faucet.testnet.networks.dash.org",
  ]
}

resource "aws_acm_certificate" "cdn" {
  region                    = local.region
  domain_name               = "networks.dash.org"
  subject_alternative_names = local.certificate_names
  validation_method         = "DNS"

  tags = merge(local.shared_tags, { Name = "testnet-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "alb" {
  region                    = local.region
  domain_name               = "networks.dash.org"
  subject_alternative_names = local.certificate_names
  validation_method         = "DNS"

  # ManagedBy is not set here although the certificate carries
  # "ManagedBy = infraclaw": the default tags replace it with "terraform".
  tags = { Name = "networks.dash.org-emergency-renewal-2026-07-30" }

  lifecycle {
    create_before_destroy = true
  }
}

# ACM asks for the same record for a name whichever certificate asks, so one
# set of records validates both certificates. The wildcard shares the record
# of networks.dash.org and is left out.
resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for o in aws_acm_certificate.cdn.domain_validation_options : o.domain_name => o
    if !startswith(o.domain_name, "*.")
  }

  zone_id = data.aws_route53_zone.networks.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 60
  records = [each.value.resource_record_value]
}
