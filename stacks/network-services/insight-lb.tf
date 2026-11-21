# Mainnet Insight: the load balancer in front of the host, its certificate
# and the one DNS name this account serves.
#
# insight.dash.org, explorer.dash.org and api.dash.org are CNAMEs to this
# load balancer in the Cloudflare zone dash.org. They are not managed here;
# output "insight" says what they must point at.

locals {
  # Insight itself. nginx on the host's port 80 only serves a static 404
  # and is not used.
  insight_port = 3001
}

# --- Certificate ----------------------------------------------------------

resource "aws_acm_certificate" "insight" {
  domain_name               = "insight.dash.org"
  subject_alternative_names = ["explorer.dash.org", "api.dash.org", "insight.dashevo.org"]
  validation_method         = "DNS"

  tags = local.insight_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ACM renews the certificate for as long as each name's validation record
# exists. The one for insight.dashevo.org is here. The three for the
# dash.org names are at Cloudflare (output "insight" lists them): a new
# certificate is not issued until they have been put there by hand.
locals {
  insight_dashevo_validation = one([
    for o in aws_acm_certificate.insight.domain_validation_options : o
    if o.domain_name == "insight.dashevo.org"
  ])
}

resource "aws_route53_record" "insight_certificate_validation" {
  zone_id = data.aws_route53_zone.dashevo.zone_id
  name    = trimsuffix(local.insight_dashevo_validation.resource_record_name, ".")
  type    = local.insight_dashevo_validation.resource_record_type
  ttl     = 300
  records = [local.insight_dashevo_validation.resource_record_value]
}

# --- Load balancer --------------------------------------------------------

resource "aws_security_group" "insight_lb" {
  name        = "insight-mainnet-lb"
  description = "Mainnet Insight load balancer: web in"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(local.insight_tags, { Name = "insight-mainnet-lb" })
}

resource "aws_vpc_security_group_ingress_rule" "insight_lb_v4" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.insight_lb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_ingress_rule" "insight_lb_v6" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.insight_lb.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_egress_rule" "insight_lb" {
  security_group_id = aws_security_group.insight_lb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_lb" "insight" {
  name               = "insight-mainnet"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.insight_lb.id]
  subnets            = [for s in data.aws_subnet.default : s.id]

  tags = local.insight_tags
}

# The health check accepts any answer from 200 to 499, as the old account's
# did. It proves that Insight's port answers, not that Insight works.
resource "aws_lb_target_group" "insight" {
  name     = "insight-mainnet"
  vpc_id   = data.aws_vpc.default.id
  protocol = "HTTP"
  port     = local.insight_port

  health_check {
    path                = "/insight/"
    matcher             = "200-499"
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }

  tags = local.insight_tags
}

resource "aws_lb_target_group_attachment" "insight" {
  target_group_arn = aws_lb_target_group.insight.arn
  target_id        = aws_instance.insight.id
}

# Port 80 forwards like port 443 and does not redirect: api.dash.org is used
# by programs, and the old load balancer answered them over plain HTTP too.
resource "aws_lb_listener" "insight_http" {
  load_balancer_arn = aws_lb.insight.arn
  protocol          = "HTTP"
  port              = 80

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.insight.arn

    forward {
      target_group {
        arn = aws_lb_target_group.insight.arn
      }
    }
  }
}

resource "aws_lb_listener" "insight_https" {
  load_balancer_arn = aws_lb.insight.arn
  protocol          = "HTTPS"
  port              = 443
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.insight.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.insight.arn

    forward {
      target_group {
        arn = aws_lb_target_group.insight.arn
      }
    }
  }
}

# --- DNS ------------------------------------------------------------------

resource "aws_route53_record" "insight_dashevo" {
  zone_id = data.aws_route53_zone.dashevo.zone_id
  name    = "insight.dashevo.org"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.insight.dns_name]
}

output "insight" {
  description = "What the Cloudflare zone dash.org must say for Insight, and where the host is."
  value = {
    instance_id = aws_instance.insight.id
    host_ip     = aws_eip.insight.public_ip

    # insight.dash.org and explorer.dash.org (proxied) and api.dash.org
    # (not proxied) are CNAMEs to this.
    load_balancer = aws_lb.insight.dns_name

    # CNAME records the certificate needs at Cloudflare, by name.
    certificate_validation = {
      for o in aws_acm_certificate.insight.domain_validation_options :
      o.resource_record_name => o.resource_record_value
      if endswith(o.domain_name, ".dash.org")
    }
  }
}
