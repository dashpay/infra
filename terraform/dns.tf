# services.dash.org: the zone for shared team services.
#
# dash.org itself is a Cloudflare zone. It delegates this name to Route 53
# with four NS records, which are not managed here: changing this zone's
# name servers (recreating it) means updating those records by hand.
#
# The zone was created by hand on 2026-11-20 and is adopted here.

import {
  to = aws_route53_zone.services
  id = "Z0820566196PGHG2GBDJL"
}

resource "aws_route53_zone" "services" {
  name    = "services.dash.org"
  comment = "Shared services subdomain, delegated from Cloudflare dash.org (dashpay/infra#90)"

  lifecycle {
    prevent_destroy = true
  }
}
