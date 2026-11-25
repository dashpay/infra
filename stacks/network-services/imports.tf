# Adoption of what was built by hand and by script on 2026-11-20
# (dashpay/infra#19). Inert once applied. To build this stack from nothing,
# delete this file.

# --- Mainnet Insight: host ---

import {
  to = aws_ami.insight
  id = "ami-04d054901c7771c85"
}

import {
  to = aws_iam_role.insight
  id = "insight-ssm"
}

import {
  to = aws_iam_role_policy_attachment.insight_ssm
  id = "insight-ssm/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_instance_profile.insight
  id = "insight-ssm"
}

import {
  to = aws_security_group.insight
  id = "sg-0f9fbfdfadf45986a"
}

import {
  to = aws_vpc_security_group_ingress_rule.insight_from_lb
  id = "sgr-088f1401942f6f107"
}

import {
  to = aws_vpc_security_group_egress_rule.insight
  id = "sgr-0027b88df0c76cf1e"
}

import {
  to = aws_instance.insight
  id = "i-073cce4ac3c49b6f6"
}

import {
  to = aws_ebs_volume.insight_data
  id = "vol-03980d0865bd1cb17"
}

import {
  to = aws_volume_attachment.insight_data
  id = "/dev/sdf:vol-03980d0865bd1cb17:i-073cce4ac3c49b6f6"
}

import {
  to = aws_eip.insight
  id = "eipalloc-0ff5b13e3484bbf45"
}

import {
  to = aws_eip_association.insight
  id = "eipassoc-050b094fdda9d28df"
}

# --- Mainnet Insight: load balancer, certificate, DNS ---

import {
  to = aws_acm_certificate.insight
  id = "arn:aws:acm:us-west-2:854439639386:certificate/2bc38cc1-b717-45bb-92b3-c20b91e3648c"
}

import {
  to = aws_route53_record.insight_certificate_validation
  id = "${data.aws_route53_zone.dashevo.zone_id}__eae9f075171efc3d05daba92779c2617.insight.dashevo.org_CNAME"
}

import {
  to = aws_security_group.insight_lb
  id = "sg-047057f5effaca8fa"
}

import {
  to = aws_vpc_security_group_ingress_rule.insight_lb_v4["http"]
  id = "sgr-00f3493e2011e48d9"
}

import {
  to = aws_vpc_security_group_ingress_rule.insight_lb_v4["https"]
  id = "sgr-092e9fc79a84622d5"
}

import {
  to = aws_vpc_security_group_ingress_rule.insight_lb_v6["http"]
  id = "sgr-091241bad70564476"
}

import {
  to = aws_vpc_security_group_ingress_rule.insight_lb_v6["https"]
  id = "sgr-0fdc3616cb6fd502b"
}

import {
  to = aws_vpc_security_group_egress_rule.insight_lb
  id = "sgr-0c96012887bb06b97"
}

import {
  to = aws_lb.insight
  id = "arn:aws:elasticloadbalancing:us-west-2:854439639386:loadbalancer/app/insight-mainnet/4358c46a732b94b6"
}

import {
  to = aws_lb_target_group.insight
  id = "arn:aws:elasticloadbalancing:us-west-2:854439639386:targetgroup/insight-mainnet/d406d9259121d505"
}

import {
  to = aws_lb_target_group_attachment.insight
  id = "arn:aws:elasticloadbalancing:us-west-2:854439639386:targetgroup/insight-mainnet/d406d9259121d505,i-073cce4ac3c49b6f6"
}

import {
  to = aws_lb_listener.insight_http
  id = "arn:aws:elasticloadbalancing:us-west-2:854439639386:listener/app/insight-mainnet/4358c46a732b94b6/12edba24165216ad"
}

import {
  to = aws_lb_listener.insight_https
  id = "arn:aws:elasticloadbalancing:us-west-2:854439639386:listener/app/insight-mainnet/4358c46a732b94b6/228cc6d00fff4c3b"
}

import {
  to = aws_route53_record.insight_dashevo
  id = "${data.aws_route53_zone.dashevo.zone_id}_insight.dashevo.org_CNAME"
}

# --- DNS seeders ---

import {
  to = aws_iam_role.dnsseed
  id = "dnsseed-ssm"
}

import {
  to = aws_iam_role_policy_attachment.dnsseed_ssm
  id = "dnsseed-ssm/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_instance_profile.dnsseed
  id = "dnsseed-ssm"
}

import {
  to = aws_security_group.dnsseed
  id = "sg-04d1b8319eabb188c"
}

import {
  to = aws_vpc_security_group_ingress_rule.dnsseed_dns
  id = "sgr-093e1ec677c1fb84e"
}

import {
  to = aws_vpc_security_group_egress_rule.dnsseed
  id = "sgr-079271b9dc4f80c38"
}

import {
  to = aws_instance.dnsseed["mainnet"]
  id = "i-0d470e47f25c193cb"
}

import {
  to = aws_instance.dnsseed["testnet"]
  id = "i-00fb89015250ca17c"
}

import {
  to = aws_eip.dnsseed["mainnet"]
  id = "eipalloc-0e3de1dfa230c1af6"
}

import {
  to = aws_eip.dnsseed["testnet"]
  id = "eipalloc-09c70e853e07da6a0"
}

import {
  to = aws_eip_association.dnsseed["mainnet"]
  id = "eipassoc-01bda6089bb8ed6b0"
}

import {
  to = aws_eip_association.dnsseed["testnet"]
  id = "eipassoc-01564ddeeea258ce9"
}
