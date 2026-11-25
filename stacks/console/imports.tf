# The import blocks that adopted the console's footing, all of it made by
# hand before this stack existed. They are inert once applied. To build the
# stack from nothing, delete this file.

# --- The status host

import {
  to = aws_security_group.status
  id = "sg-00811ad19ea63b075"
}

import {
  to = aws_vpc_security_group_ingress_rule.status_web["HTTP"]
  id = "sgr-06573a5314851ce04"
}

import {
  to = aws_vpc_security_group_ingress_rule.status_web["HTTPS"]
  id = "sgr-0d4f07b8a6e303b84"
}

import {
  to = aws_vpc_security_group_egress_rule.status_v4
  id = "sgr-06899a722a8594ece"
}

import {
  to = aws_vpc_security_group_egress_rule.status_v6
  id = "sgr-08323d5c5307c3e76"
}

import {
  to = aws_instance.status
  id = "i-0089435363e96c711"
}

import {
  to = aws_eip.status
  id = "eipalloc-070412cc8b4ce5ab0"
}

import {
  to = aws_eip_association.status
  id = "eipassoc-0d045fcf341bd1d4b"
}

# --- The host's role

import {
  to = aws_iam_role.status_server
  id = "dash-status-server"
}

import {
  to = aws_iam_instance_profile.status_server
  id = "dash-status-server"
}

import {
  to = aws_iam_role_policy.status_agent
  id = "dash-status-server:status-agent"
}

import {
  to = aws_iam_role_policy.status_inventory
  id = "dash-status-server:status-inventory"
}

# --- The operations roles

import {
  for_each = local.operations_roles
  to       = aws_iam_role.operations[each.key]
  id       = each.key
}

import {
  for_each = local.operations_roles
  to       = aws_iam_role_policy.operations[each.key]
  id       = "${each.key}:exact-network-operations"
}

# --- The operations bucket

import {
  to = aws_s3_bucket.operations
  id = "dash-status-operations-854439639386-usw2"
}

import {
  to = aws_s3_bucket_versioning.operations
  id = "dash-status-operations-854439639386-usw2"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.operations
  id = "dash-status-operations-854439639386-usw2"
}

import {
  to = aws_s3_bucket_public_access_block.operations
  id = "dash-status-operations-854439639386-usw2"
}

import {
  to = aws_s3_bucket_ownership_controls.operations
  id = "dash-status-operations-854439639386-usw2"
}

import {
  to = aws_s3_bucket_policy.operations
  id = "dash-status-operations-854439639386-usw2"
}

# --- The engine's table

import {
  to = aws_dynamodb_table.managed_state
  id = "dashnet-managed-state"
}

# --- The devnet scaffolding

import {
  to = aws_vpc.devnets
  id = "vpc-08b7a214713ca4ce9"
}

import {
  to = aws_subnet.devnets
  id = "subnet-01765e4b0fc0a2aa4"
}

import {
  to = aws_internet_gateway.devnets
  id = "igw-0bcb33c170ec9a240"
}

import {
  to = aws_route_table.devnets
  id = "rtb-0f34c9836047cbed2"
}

import {
  to = aws_route_table_association.devnets
  id = "subnet-01765e4b0fc0a2aa4/rtb-0f34c9836047cbed2"
}

import {
  to = aws_key_pair.status_agent
  id = "dash-status-agent"
}

import {
  to = aws_security_group.devnet_nodes
  id = "sg-0246983c2e14a5f34"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_public["http-acme"]
  id = "sgr-0d8d4d104efb46a30"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_public["https-services"]
  id = "sgr-0eb0164e73b8d1e03"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_public["dapi"]
  id = "sgr-0310559d4737524bf"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_public["core-p2p"]
  id = "sgr-0c8ffdbe68cb343da"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_public["tenderdash-p2p"]
  id = "sgr-0cdfbaee0cdd94a3a"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_fleet
  id = "sgr-00e6cfc5f15e5da11"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_ssh_status_agent
  id = "sgr-01c4087e1726b05b7"
}

import {
  to = aws_vpc_security_group_ingress_rule.devnet_ssh_anywhere
  id = "sgr-04948a547f77227f5"
}

import {
  to = aws_vpc_security_group_egress_rule.devnet_nodes
  id = "sgr-01cbc979b59568493"
}

# --- DNS

import {
  to = aws_route53_record.status
  id = "${data.aws_route53_zone.networks.zone_id}_status.testnet.networks.dash.org_A"
}
