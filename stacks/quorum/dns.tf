# networks.dash.org belongs to the dns stack. This stack only puts its own
# records in it: quorums.testnet, quorums.mainnet and the certificates'
# validation records.
data "aws_route53_zone" "networks" {
  name = "networks.dash.org"
}

locals {
  # Without the trailing dot Route 53 gives it.
  zone_name = trimsuffix(data.aws_route53_zone.networks.name, ".")
}
