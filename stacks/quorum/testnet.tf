# The testnet quorum list: https://quorums.testnet.networks.dash.org
module "testnet" {
  source = "../../modules/quorum-network"

  providers = {
    aws                 = aws
    aws.no_default_tags = aws.no_default_tags
  }

  network = "testnet"
  region  = local.region

  vpc_id                    = aws_vpc.main.id
  vpc_cidr                  = local.vpc_cidr
  host_subnet_id            = aws_subnet.private["1"].id
  efs_subnet_ids            = { for k, s in aws_subnet.private : k => s.id }
  bastion_security_group_id = aws_security_group.bastion.id

  # As found: testnet's file system has had a replica in us-west-2 since
  # 2025-07-01 (fs-0b16425667dc840cb). Mainnet's has none.
  efs_replica_region = "us-west-2"

  ami_id          = data.aws_ami.ubuntu.id
  key_name        = local.key_name
  core_private_ip = "10.0.10.199"

  # What a rebuilt backend would install: the release testnet's nodes were
  # moved to in November 2026. The running host was last recorded on a
  # 24.0.0 nightly (2026-09-23) and has not been checked since.
  core_version = "24.0.2"

  # According to the operations notes the quorum server needs this from
  # Core 24, and it was added to the live dash.conf by hand in September
  # 2026. Not checked on the host.
  core_conf_extra = ["deprecatedrpc=service"]

  # As found: RPC is also open to every private 10.x address, not only to
  # the quorum server. Mainnet has no such rule.
  core_rpc_extra_cidrs = ["10.0.0.0/8"]

  quorum_server_version = local.quorum_server_version

  alb_security_group_id  = aws_security_group.alb.id
  alb_dns_name           = aws_lb.main.dns_name
  listener_arn           = aws_lb_listener.https.arn
  listener_rule_priority = 150

  zone_id             = data.aws_route53_zone.networks.zone_id
  zone_name           = local.zone_name
  cdn_certificate_arn = aws_acm_certificate.cdn.arn
  cdn_template_body   = file("${path.module}/files/quorums-cdn.yaml")
}
