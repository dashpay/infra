# The mainnet quorum list: https://quorums.mainnet.networks.dash.org
#
# Mainnet clients depend on it. Plan a change here as carefully as its size
# deserves, and read the plan for anything that says "replace".
module "mainnet" {
  source = "../../modules/quorum-network"

  providers = {
    aws                 = aws
    aws.no_default_tags = aws.no_default_tags
  }

  network = "mainnet"
  region  = local.region

  vpc_id                    = aws_vpc.main.id
  vpc_cidr                  = local.vpc_cidr
  host_subnet_id            = aws_subnet.private["1"].id
  efs_subnet_ids            = { for k, s in aws_subnet.private : k => s.id }
  bastion_security_group_id = aws_security_group.bastion.id

  ami_id          = data.aws_ami.ubuntu.id
  key_name        = local.key_name
  core_private_ip = "10.0.10.249"

  # What the backend runs since 2026-10-05, when it was upgraded by hand
  # from 22.1.2. That upgrade migrated the data directory, so a rebuilt
  # backend must not install anything older.
  core_version = "23.1.8"

  quorum_server_version = local.quorum_server_version

  alb_security_group_id  = aws_security_group.alb.id
  alb_dns_name           = aws_lb.main.dns_name
  listener_arn           = aws_lb_listener.https.arn
  listener_rule_priority = 200

  # The module's own quorum server (mainnet-quorum-server) is not the one
  # that serves: see mainnet-recovery-host.tf.
  serving_instance_id = aws_instance.mainnet_quorum_recovery.id

  zone_id             = data.aws_route53_zone.networks.zone_id
  zone_name           = local.zone_name
  cdn_certificate_arn = aws_acm_certificate.cdn.arn
  cdn_template_body   = file("${path.module}/files/quorums-cdn.yaml")

  # First boot needs the NAT route; see testnet.tf.
  depends_on = [aws_route_table_association.private, aws_route_table_association.public]
}
