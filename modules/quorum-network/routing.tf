# This network's place on the shared load balancer: a target group, and one
# rule that sends requests for its public name there.

resource "aws_lb_target_group" "quorum" {
  region   = var.region
  name     = "${var.network}-quorum-tg"
  port     = local.quorum_server_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.tags, { Name = "${var.network}-quorum-tg" })
}

# No port here: the target is registered on the target group's own port.
#
# Changing the target here makes Terraform take the old instance out and
# then put the new one in, with nothing registered in between. On mainnet do
# the switch by hand first (register, wait for healthy, deregister: the
# README says how) and change the configuration afterwards to match.
resource "aws_lb_target_group_attachment" "quorum" {
  region           = var.region
  target_group_arn = aws_lb_target_group.quorum.arn
  target_id        = coalesce(var.serving_instance_id, aws_instance.quorum_server.id)
}

# Rules are separate resources, so the other services' rules on the same
# listener are not this module's to change or remove.
resource "aws_lb_listener_rule" "quorum" {
  region       = var.region
  listener_arn = var.listener_arn
  priority     = var.listener_rule_priority

  condition {
    host_header {
      values = [local.hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.quorum.arn
  }
}
