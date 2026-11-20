# Adoption of what already existed on 2026-11-20. Inert once applied. To
# build this stack from nothing, delete this file.
#
# Where each thing came from:
# - the three Terraform states of dashpay/quorum-list-server
#   (s3://dash-terraform-state-854439639386/quorum-list-server/base, testnet
#   and mainnet), last applied on 2025-07-01. This stack replaces them: they
#   are to be retired and never applied again;
# - made by hand, in no state: the replica of testnet's file system
#   (2025-07-01), the second certificate (2026-07-30), the two CloudFormation
#   stacks and the AAAA and HTTPS records (2026-09-16), the mainnet recovery
#   host and its SSH group (2026-10-05).

# --- Network (state: base) ---

import {
  to = aws_vpc.main
  id = "vpc-07f770de37f40a9a9@us-east-1"
}

import {
  to = aws_internet_gateway.main
  id = "igw-0904e655b11117a08@us-east-1"
}

import {
  to = aws_subnet.public["1"]
  id = "subnet-0a92661086551c6c9@us-east-1"
}

import {
  to = aws_subnet.public["2"]
  id = "subnet-0a0ab8d6ed9ed552b@us-east-1"
}

import {
  to = aws_subnet.private["1"]
  id = "subnet-0368623372ab30239@us-east-1"
}

import {
  to = aws_subnet.private["2"]
  id = "subnet-05b22e4f5e922767a@us-east-1"
}

import {
  to = aws_eip.nat
  id = "eipalloc-089d64acd9049e37e@us-east-1"
}

import {
  to = aws_nat_gateway.main
  id = "nat-03dfe700a5feb9376@us-east-1"
}

import {
  to = aws_route_table.public
  id = "rtb-0d5378570e3935697@us-east-1"
}

import {
  to = aws_route_table.private
  id = "rtb-05d5e36f529f0ff89@us-east-1"
}

import {
  to = aws_route_table_association.public["1"]
  id = "subnet-0a92661086551c6c9/rtb-0d5378570e3935697@us-east-1"
}

import {
  to = aws_route_table_association.public["2"]
  id = "subnet-0a0ab8d6ed9ed552b/rtb-0d5378570e3935697@us-east-1"
}

import {
  to = aws_route_table_association.private["1"]
  id = "subnet-0368623372ab30239/rtb-05d5e36f529f0ff89@us-east-1"
}

import {
  to = aws_route_table_association.private["2"]
  id = "subnet-05b22e4f5e922767a/rtb-05d5e36f529f0ff89@us-east-1"
}

# --- Certificates and their validation records (state: base, except the second certificate) ---

import {
  to = aws_acm_certificate.cdn
  id = "arn:aws:acm:us-east-1:854439639386:certificate/4a4e923a-c7ea-47fb-8b35-42d532995f66@us-east-1"
}

import {
  to = aws_acm_certificate.alb
  id = "arn:aws:acm:us-east-1:854439639386:certificate/845ba924-b221-4430-bb47-6d2c258d6b37@us-east-1"
}

import {
  to = aws_route53_record.certificate_validation["networks.dash.org"]
  id = "${data.aws_route53_zone.networks.zone_id}__c976d389cdde62776351d7e9e62dc3a8.networks.dash.org_CNAME"
}

import {
  to = aws_route53_record.certificate_validation["quorums.testnet.networks.dash.org"]
  id = "${data.aws_route53_zone.networks.zone_id}__4697b5a005f4bb72636f8333f3f3c6a9.quorums.testnet.networks.dash.org_CNAME"
}

import {
  to = aws_route53_record.certificate_validation["quorums.mainnet.networks.dash.org"]
  id = "${data.aws_route53_zone.networks.zone_id}__a6491196a2a4b74e0003220da4f8eef5.quorums.mainnet.networks.dash.org_CNAME"
}

import {
  to = aws_route53_record.certificate_validation["faucet.testnet.networks.dash.org"]
  id = "${data.aws_route53_zone.networks.zone_id}__0b8fc112628b24d6ebf76e8bf0d4a9e7.faucet.testnet.networks.dash.org_CNAME"
}

# --- Load balancer (state: base) ---

import {
  to = aws_security_group.alb
  id = "sg-078d2f2695fd69a04@us-east-1"
}

import {
  to = aws_vpc_security_group_ingress_rule.alb["http"]
  id = "sgr-042fb032db52db107@us-east-1"
}

import {
  to = aws_vpc_security_group_ingress_rule.alb["https"]
  id = "sgr-04f0bb6539164fb38@us-east-1"
}

import {
  to = aws_vpc_security_group_egress_rule.alb
  id = "sgr-0578f811ed1349f78@us-east-1"
}

import {
  to = aws_lb.main
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:loadbalancer/app/testnet-alb/3ead1a1f475824bb@us-east-1"
}

import {
  to = aws_lb_listener.https
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:listener/app/testnet-alb/3ead1a1f475824bb/2dfd16c4e63eb796@us-east-1"
}

# --- Bastion (state: base) ---

import {
  to = aws_security_group.bastion
  id = "sg-043f3f4bdb996811c@us-east-1"
}

import {
  to = aws_vpc_security_group_ingress_rule.bastion_ssh
  id = "sgr-0f17f1c4a389c508d@us-east-1"
}

import {
  to = aws_vpc_security_group_egress_rule.bastion
  id = "sgr-0ce226e0e655dc8a6@us-east-1"
}

import {
  to = aws_instance.bastion
  id = "i-0f0ec58452621d944@us-east-1"
}

# --- Testnet (state: testnet, except what the header lists) ---

import {
  to = module.testnet.aws_security_group.core
  id = "sg-038f86f41a477049d@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.core_ssh
  id = "sgr-096b022d9c72503dc@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.core_rpc
  id = "sgr-0651df5ebe414db68@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.core_rpc_cidr["10.0.0.0/8"]
  id = "sgr-04d872354748b6892@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.core_p2p
  id = "sgr-0e5595b6e89985739@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_egress_rule.core
  id = "sgr-0c70b882d058ea378@us-east-1"
}

import {
  to = module.testnet.aws_instance.core
  id = "i-05df23b03249bacab@us-east-1"
}

import {
  to = module.testnet.aws_security_group.quorum_server
  id = "sg-04c630853510457de@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.quorum_server_ssh
  id = "sgr-01638f4d063e3f848@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.quorum_server_http
  id = "sgr-0216fdfe90af7c56c@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_egress_rule.quorum_server
  id = "sgr-04f54bafa62ab744b@us-east-1"
}

import {
  to = module.testnet.aws_instance.quorum_server
  id = "i-0aedbd5e5cb37bdee@us-east-1"
}

import {
  to = module.testnet.aws_efs_file_system.core
  id = "fs-0723d882ceada6c38@us-east-1"
}

import {
  to = module.testnet.aws_efs_mount_target.core["1"]
  id = "fsmt-0c2304c7da6e2523c@us-east-1"
}

import {
  to = module.testnet.aws_efs_mount_target.core["2"]
  id = "fsmt-02e527c3a94469c78@us-east-1"
}

import {
  to = module.testnet.aws_efs_replication_configuration.core[0]
  id = "fs-0723d882ceada6c38@us-east-1"
}

import {
  to = module.testnet.aws_security_group.efs
  id = "sg-0609e23dbc047837d@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_ingress_rule.efs_nfs
  id = "sgr-0caae27c39d5b1381@us-east-1"
}

import {
  to = module.testnet.aws_vpc_security_group_egress_rule.efs
  id = "sgr-00bcbefee445a93a8@us-east-1"
}

import {
  to = module.testnet.aws_lb_target_group.quorum
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:targetgroup/testnet-quorum-tg/7b6c7170f0377332@us-east-1"
}

import {
  to = module.testnet.aws_lb_target_group_attachment.quorum
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:targetgroup/testnet-quorum-tg/7b6c7170f0377332,i-0aedbd5e5cb37bdee@us-east-1"
}

import {
  to = module.testnet.aws_lb_listener_rule.quorum
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:listener-rule/app/testnet-alb/3ead1a1f475824bb/2dfd16c4e63eb796/22615ca31dc59290@us-east-1"
}

import {
  to = module.testnet.aws_cloudformation_stack.cdn
  id = "quorums-cdn-testnet@us-east-1"
}

import {
  to = module.testnet.aws_route53_record.cdn["A"]
  id = "${data.aws_route53_zone.networks.zone_id}_quorums.testnet.networks.dash.org_A"
}

import {
  to = module.testnet.aws_route53_record.cdn["AAAA"]
  id = "${data.aws_route53_zone.networks.zone_id}_quorums.testnet.networks.dash.org_AAAA"
}

import {
  to = module.testnet.aws_route53_record.cdn_https
  id = "${data.aws_route53_zone.networks.zone_id}_quorums.testnet.networks.dash.org_HTTPS"
}

# --- Mainnet (state: mainnet, except what the header lists) ---

import {
  to = module.mainnet.aws_security_group.core
  id = "sg-0400be86c6ea380a7@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_ingress_rule.core_ssh
  id = "sgr-0d970c0b9f56db31f@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_ingress_rule.core_rpc
  id = "sgr-03c8de377620d240e@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_ingress_rule.core_p2p
  id = "sgr-0663d81fdd3150899@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_egress_rule.core
  id = "sgr-0c3bb629300cbcb82@us-east-1"
}

import {
  to = module.mainnet.aws_instance.core
  id = "i-0702105c9f0861601@us-east-1"
}

import {
  to = module.mainnet.aws_security_group.quorum_server
  id = "sg-0fd0eb0b2f7cd7c83@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_ingress_rule.quorum_server_ssh
  id = "sgr-0998affd619adddca@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_ingress_rule.quorum_server_http
  id = "sgr-05ec3aae4a41798e5@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_egress_rule.quorum_server
  id = "sgr-0c0c769bf4e68c302@us-east-1"
}

import {
  to = module.mainnet.aws_instance.quorum_server
  id = "i-094434fbc0847aac7@us-east-1"
}

import {
  to = module.mainnet.aws_efs_file_system.core
  id = "fs-07e047ed384c75355@us-east-1"
}

import {
  to = module.mainnet.aws_efs_mount_target.core["1"]
  id = "fsmt-0f34f8eb083bdcc7e@us-east-1"
}

import {
  to = module.mainnet.aws_efs_mount_target.core["2"]
  id = "fsmt-0872dda56074830cb@us-east-1"
}

import {
  to = module.mainnet.aws_security_group.efs
  id = "sg-03aa881f30de4384a@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_ingress_rule.efs_nfs
  id = "sgr-06b4f23dd83df2b32@us-east-1"
}

import {
  to = module.mainnet.aws_vpc_security_group_egress_rule.efs
  id = "sgr-001dd80286ad8a7d9@us-east-1"
}

import {
  to = module.mainnet.aws_lb_target_group.quorum
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:targetgroup/mainnet-quorum-tg/058bb5f68373140b@us-east-1"
}

# The target is the recovery host. The instance the old state had registered
# (i-094434fbc0847aac7) was taken out of the group on 2026-10-05.
import {
  to = module.mainnet.aws_lb_target_group_attachment.quorum
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:targetgroup/mainnet-quorum-tg/058bb5f68373140b,i-03b4a78195dd8b42e@us-east-1"
}

import {
  to = module.mainnet.aws_lb_listener_rule.quorum
  id = "arn:aws:elasticloadbalancing:us-east-1:854439639386:listener-rule/app/testnet-alb/3ead1a1f475824bb/2dfd16c4e63eb796/57f09db7e8e3a46b@us-east-1"
}

import {
  to = module.mainnet.aws_cloudformation_stack.cdn
  id = "quorums-cdn-mainnet@us-east-1"
}

import {
  to = module.mainnet.aws_route53_record.cdn["A"]
  id = "${data.aws_route53_zone.networks.zone_id}_quorums.mainnet.networks.dash.org_A"
}

import {
  to = module.mainnet.aws_route53_record.cdn["AAAA"]
  id = "${data.aws_route53_zone.networks.zone_id}_quorums.mainnet.networks.dash.org_AAAA"
}

import {
  to = module.mainnet.aws_route53_record.cdn_https
  id = "${data.aws_route53_zone.networks.zone_id}_quorums.mainnet.networks.dash.org_HTTPS"
}

# --- Mainnet recovery host (made by hand on 2026-10-05, in no state) ---

import {
  to = aws_security_group.mainnet_quorum_recovery_ssh
  id = "sg-08968b30224b76e00@us-east-1"
}

import {
  to = aws_vpc_security_group_ingress_rule.mainnet_quorum_recovery_ssh
  id = "sgr-07d08c41f26f7fff9@us-east-1"
}

import {
  to = aws_vpc_security_group_egress_rule.mainnet_quorum_recovery_ssh
  id = "sgr-00a29ae434b8c9fec@us-east-1"
}

import {
  to = aws_instance.mainnet_quorum_recovery
  id = "i-03b4a78195dd8b42e@us-east-1"
}
