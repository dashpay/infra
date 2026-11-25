# Domain registrations held in this account's Route 53 Domains.
#
# Terraform cannot register or delete a domain. This resource adopts a
# registration that exists and manages its settings: name servers,
# auto-renew, transfer lock, contact privacy. Destroying it only forgets it.
#
# Auto-renew, the transfer lock and contact privacy are on for all four,
# which is also the resource's default, so they are not repeated here.
# Contact details are left as they are at the registry and are deliberately
# not written in this repository.

# Registered here and served by a zone here: the registration follows the
# zone's name servers, so a recreated zone is delegated again by the same
# apply.
resource "aws_route53domains_registered_domain" "hosted" {
  for_each = toset(["dash-devnets.org", "dashevo.org", "dashtalk.org"])

  domain_name = each.key

  dynamic "name_server" {
    for_each = aws_route53_zone.this[each.key].name_servers

    content {
      name = name_server.value
    }
  }
}

# Registered here, served by Cloudflare (the same account as dash.org).
resource "aws_route53domains_registered_domain" "dashforum" {
  domain_name = "dashforum.org"

  name_server {
    name = "angela.ns.cloudflare.com"
  }

  name_server {
    name = "owen.ns.cloudflare.com"
  }
}
