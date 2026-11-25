# The public name: a CloudFront distribution in front of the shared load
# balancer, and the DNS records that point at it.
#
# The distribution is made by a CloudFormation stack (one per network, built
# by hand on 2026-09-16), not by Terraform resources. The stack also makes a
# cache policy, an origin request policy, and a Route 53 health check that
# requests /quorums every 30 seconds to keep the cache and the origin warm.
resource "aws_cloudformation_stack" "cdn" {
  # The provider without default tags. CloudFormation passes a stack's tags
  # on to the distribution and the health check, so tagging the stack is an
  # update of a live distribution. Testnet's has been changed by hand since
  # the stack made it (see the README), and an update could put it back to
  # what the template says.
  provider = aws.no_default_tags

  region        = var.region
  name          = "quorums-cdn-${var.network}"
  template_body = var.cdn_template_body

  parameters = {
    HostName           = local.hostname
    OriginDomainName   = var.alb_dns_name
    AcmCertificateArn  = var.cdn_certificate_arn
    OriginShieldRegion = var.region
    CacheTtlSeconds    = "30"
    WarmPingPath       = "/quorums"
  }

  lifecycle {
    # Deleting the stack deletes the distribution behind the public name.
    prevent_destroy = true

    # parameters: the provider cannot read the parameters of a stack it
    # adopts, so it would plan to "add" all six and send CloudFormation an
    # update that changes nothing. The values above are the stacks' own,
    # read on 2026-11-20. To change one, take this line out first, and
    # expect that one plan to list all six.
    ignore_changes = [parameters]
  }
}

locals {
  cdn_alias = {
    name = aws_cloudformation_stack.cdn.outputs["DistributionDomainName"]
    # CloudFront's own hosted zone: the same for every distribution.
    zone_id = "Z2FDTNDATAQYW2"
  }
}

resource "aws_route53_record" "cdn" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.zone_id
  name    = local.hostname
  type    = each.key

  alias {
    name                   = local.cdn_alias.name
    zone_id                = local.cdn_alias.zone_id
    evaluate_target_health = false
  }
}

# Tells clients up front that the name speaks HTTP/3 and HTTP/2, which saves
# them a round trip.
resource "aws_route53_record" "cdn_https" {
  zone_id = var.zone_id
  name    = local.hostname
  type    = "HTTPS"
  ttl     = 300
  records = ["1 . alpn=\"h3,h2\""]
}
