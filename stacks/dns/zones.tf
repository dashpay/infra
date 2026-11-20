# The public zones this account answers for. Records are in records.tf.
#
# Recreating a zone gives it four new name servers, and whoever delegates to
# it has to be told (README.md, "Rebuild from nothing"). So every zone is
# protected against destroy.
#
# `comment` is the zone's description in Route 53, kept as it was found.

locals {
  zones = {
    # Delegated from the Cloudflare zone dash.org by four NS records there.
    # Only the zone is managed here, no records: they belong to the stacks
    # that own the things they name (quorum, network-services), to the retired
    # network tooling, and to the status console, which writes devnet names
    # into the zone while it runs.
    "networks.dash.org" = { comment = "" }

    # Delegated from Cloudflare dash.org the same way. Holds the SendGrid
    # subscription endpoint, sg.subscribe.dash.org.
    "subscribe.dash.org" = { comment = "" }

    # Registered in this account (domains.tf). Empty: the status console
    # names devnets under networks.dash.org.
    "dash-devnets.org" = { comment = "HostedZone created by Route53 Registrar" }

    # The five zones moved from the dashevo account on 2026-11-20
    # (dashpay/infra#19). dashevo.org and dashtalk.org are registered in this
    # account (domains.tf); dashmate.org, grovedb.org and dashpay.io at
    # NameCheap, account `dashpay`.
    "dashevo.org"  = { comment = "moved from the dashevo account, dashpay/infra#19" }
    "dashtalk.org" = { comment = "moved from the dashevo account, dashpay/infra#19" }
    "dashmate.org" = { comment = "moved from the dashevo account, dashpay/infra#19" }
    "dashpay.io"   = { comment = "moved from the dashevo account, dashpay/infra#19" }
    "grovedb.org"  = { comment = "moved from the dashevo account, dashpay/infra#19" }
  }
}

resource "aws_route53_zone" "this" {
  for_each = local.zones

  name    = each.key
  comment = each.value.comment

  lifecycle {
    prevent_destroy = true
  }
}
