# status.testnet.networks.dash.org: the console's public name.
#
# The zone belongs to the dns stack. This is the only record in it that this
# stack owns. `status.dash.org` redirects here.
#
# The console writes into the same zone: the service names of each devnet
# (`explorer.<devnet>.networks.dash.org` and so on). Those are the console's
# own and are declared nowhere in Terraform. The console's role is denied
# any change to a name under `testnet.networks.dash.org` (host-role.tf), so
# it cannot touch this record.
resource "aws_route53_record" "status" {
  zone_id = data.aws_route53_zone.networks.zone_id
  name    = "status.testnet.networks.dash.org"
  type    = "A"
  ttl     = 300
  records = [aws_eip.status.public_ip]
}
