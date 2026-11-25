# One network's quorum list service: a Dash Core backend with its data on
# EFS, the quorum server that reads from it, and the way in from the public
# name (CloudFront, then a rule on the shared load balancer).
#
#   quorums.<network>.networks.dash.org
#     -> CloudFront (cdn.tf)
#     -> shared load balancer, host-header rule (routing.tf)
#     -> quorum server, port 3000 (quorum-server.tf)
#     -> Core RPC (core.tf), data directory on EFS (efs.tf)
#
# The VPC, the load balancer, the bastion and the certificates are shared by
# both networks and belong to the stack that calls this module.

locals {
  # Dash's own port numbers.
  core_ports = {
    mainnet = { p2p = 9999, rpc = 9998 }
    testnet = { p2p = 19999, rpc = 19998 }
  }
  core_p2p_port = local.core_ports[var.network].p2p
  core_rpc_port = local.core_ports[var.network].rpc

  # The quorum server listens here. The load balancer and its health check
  # use the same port.
  quorum_server_port = 3000

  hostname = "quorums.${var.network}.${var.zone_name}"

  tags = { Environment = var.network }
}
