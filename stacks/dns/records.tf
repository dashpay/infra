# Records that do not belong to a service in another stack.
#
# A record that exists for something another stack manages is declared
# there, beside that thing: the sites' aliases, certificate validation
# records and `_<host>` proof records are in `web`; insight.dashevo.org and
# its certificate's validation record are in `network-services`. A record
# added by hand to one of these zones does not show up in a plan; write it
# here.
#
# Every record here has a TTL of 300 seconds. The key is "<name> <type>".

locals {
  records = {
    "subscribe.dash.org" = {
      # The SendGrid subscription API: an API Gateway custom domain in
      # us-west-2 (API `sendgrid-api`), made by hand and not in Terraform.
      # The second record keeps that domain's ACM certificate renewing.
      "sg.subscribe.dash.org CNAME"                                   = ["d-3hap8xloll.execute-api.us-west-2.amazonaws.com"]
      "_e6635a39c92c9738a4f5f3b879adad2e.sg.subscribe.dash.org CNAME" = ["_f0cc6d4a4601522aaeccc4cd97507753.xlfgrmvvlj.acm-validations.aws."]
    }

    "dashevo.org" = {
      # Validates the certificate `*.dashevo.org` in us-east-1, which nothing
      # uses (seen 2026-11-20).
      "_466399441d9e1ff21bfc4724d41de8e8.dashevo.org CNAME" = ["_645da0b07450b2d4fd1e294db35ba23c.duyqrilejt.acm-validations.aws."]
      # Left from a certificate of the dashevo account. Matches no
      # certificate in this account.
      "_d7cb6105abd1fa9d126516a7fe059020.dashevo.org CNAME" = ["_bbcf3a8960d85737c94fd575433fe709.acm-validations.aws."]
    }

    "dashtalk.org" = {
      # A host at DigitalOcean that redirects both names to
      # https://www.dash.org/forum/.
      "dashtalk.org A"     = ["134.209.142.225"]
      "www.dashtalk.org A" = ["134.209.142.225"]
    }

    "dashmate.org" = {
      # A host at DigitalOcean that redirects the bare name to
      # https://www.dashmate.org/ (the site itself is in the `web` stack).
      "dashmate.org A" = ["138.197.206.232"]
      # Left from certificates of the dashevo account.
      "_70664246ad2a5a27d7106d97b83988cb.dashmate.org CNAME"     = ["_33584a51d32ab31a9740c12dd1b84d03.fbnrgqtmtt.acm-validations.aws."]
      "_2985f7e6f4fe4e3df5f3b4afeef94f8e.www.dashmate.org CNAME" = ["_b5bc317ac3164d184fd499db3ce16381.fbnrgqtmtt.acm-validations.aws."]
    }

    "grovedb.org" = {
      # The same DigitalOcean host as dashtalk.org; it redirects the bare
      # name to https://www.grovedb.org/.
      "grovedb.org A" = ["134.209.142.225"]
      # Left from a certificate of the dashevo account.
      "_7cd1bd1f8c9a8dfbd812ec0d68d51da1.grovedb.org CNAME" = ["_72cc40274aef1ce4622b78116939c0c0.wmqxbylrnj.acm-validations.aws."]
    }

    "dashpay.io" = {
      # DashPay invitation links, served by Firebase Hosting.
      "invitations.dashpay.io A" = ["199.36.158.100"]
      # Left from a certificate of the dashevo account.
      "_e880d1ae38f1dc6e1377889c613afb30.dashpay.io CNAME" = ["_3521d8638a6012802f5bf9cdf0763dcb.fpwkmzyskh.acm-validations.aws."]
    }
  }

  records_by_key = merge([
    for zone, records in local.records : {
      for key, values in records : key => {
        zone   = zone
        name   = split(" ", key)[0]
        type   = split(" ", key)[1]
        values = values
      }
    }
  ]...)
}

resource "aws_route53_record" "this" {
  for_each = local.records_by_key

  zone_id = aws_route53_zone.this[each.value.zone].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = each.value.values
}
