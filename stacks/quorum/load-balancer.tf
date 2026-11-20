# The load balancer shared by both networks, and by the testnet faucet.
#
# It is called testnet-alb and serves mainnet too. The name cannot be
# changed without replacing it, and the two CloudFront distributions and the
# faucet's DNS record point at its DNS name.
#
# One HTTPS listener. A request is routed by its Host header: each network's
# module adds one rule (priorities 150 and 200), the faucet has four rules
# of its own (90, 91, 92, 100) that are not managed here, and anything else
# gets a 404.

# In: 80 and 443 from anywhere. Nothing listens on 80.
resource "aws_security_group" "alb" {
  region      = local.region
  name        = "testnet-quorum-alb-sg"
  description = "Security group for Quorum ALB"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.shared_tags, { Name = "testnet-quorum-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { http = 80, https = 443 }

  region            = local.region
  security_group_id = aws_security_group.alb.id
  description       = "${upper(each.key)} from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  region            = local.region
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_lb" "main" {
  region             = local.region
  name               = "testnet-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = merge(local.shared_tags, { Name = "testnet-alb" })

  lifecycle {
    # A new load balancer has a new DNS name, and both distributions and
    # the faucet's record would point at nothing.
    prevent_destroy = true
  }
}

resource "aws_lb_listener" "https" {
  region            = local.region
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.alb.arn

  # As found: the oldest predefined policy, which still accepts TLS 1.0.
  # Only CloudFront (TLS 1.2) and the faucet's visitors connect here.
  ssl_policy = "ELBSecurityPolicy-2016-08"

  # A Host header no rule knows.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}
