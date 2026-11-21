# Zones, by zone id.
import {
  for_each = {
    "networks.dash.org"  = "Z0875113JJTK7DOU978T"
    "subscribe.dash.org" = "Z0656385NGCSSIGYGDF5"
    "dash-devnets.org"   = "Z1ZCG6TZA6WXK1"
    "dashevo.org"        = "Z0522352DLSIF3XVV1HS"
    "dashtalk.org"       = "Z05168302KJ9T3KRDFDSC"
    "dashmate.org"       = "Z05777733SJY8P7JLTXTI"
    "dashpay.io"         = "Z10328341P85UO9LYIGM"
    "grovedb.org"        = "Z10323483BDUSECDK54BZ"
  }

  to = aws_route53_zone.this[each.key]
  id = each.value
}

# Registrations, by domain name.
import {
  for_each = toset(["dash-devnets.org", "dashevo.org", "dashtalk.org"])

  to = aws_route53domains_registered_domain.hosted[each.key]
  id = each.key
}

import {
  to = aws_route53domains_registered_domain.dashforum
  id = "dashforum.org"
}

# Records are imported as "<zone id>_<name>_<type>".
import {
  for_each = {
    "sg.subscribe.dash.org CNAME"                                   = "Z0656385NGCSSIGYGDF5"
    "_e6635a39c92c9738a4f5f3b879adad2e.sg.subscribe.dash.org CNAME" = "Z0656385NGCSSIGYGDF5"
    "_466399441d9e1ff21bfc4724d41de8e8.dashevo.org CNAME"           = "Z0522352DLSIF3XVV1HS"
    "_d7cb6105abd1fa9d126516a7fe059020.dashevo.org CNAME"           = "Z0522352DLSIF3XVV1HS"
    "dashtalk.org A"                                                = "Z05168302KJ9T3KRDFDSC"
    "www.dashtalk.org A"                                            = "Z05168302KJ9T3KRDFDSC"
    "dashmate.org A"                                                = "Z05777733SJY8P7JLTXTI"
    "_70664246ad2a5a27d7106d97b83988cb.dashmate.org CNAME"          = "Z05777733SJY8P7JLTXTI"
    "_2985f7e6f4fe4e3df5f3b4afeef94f8e.www.dashmate.org CNAME"      = "Z05777733SJY8P7JLTXTI"
    "grovedb.org A"                                                 = "Z10323483BDUSECDK54BZ"
    "_7cd1bd1f8c9a8dfbd812ec0d68d51da1.grovedb.org CNAME"           = "Z10323483BDUSECDK54BZ"
    "invitations.dashpay.io A"                                      = "Z10328341P85UO9LYIGM"
    "_e880d1ae38f1dc6e1377889c613afb30.dashpay.io CNAME"            = "Z10328341P85UO9LYIGM"
  }

  to = aws_route53_record.this[each.key]
  id = "${each.value}_${replace(each.key, " ", "_")}"
}
