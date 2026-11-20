output "status_host" {
  description = "The status host."
  value = {
    url         = "https://${aws_route53_record.status.name}"
    public_ip   = aws_eip.status.public_ip
    instance_id = aws_instance.status.id
    role_arn    = aws_iam_role.status_server.arn
  }
}

output "devnet_scaffolding" {
  description = "What the console's settings must name (Settings, new devnet defaults; `aws` and `devnets` in shared/settings.js of dashpay/status)."
  value = {
    vpcId            = aws_vpc.devnets.id
    subnetId         = aws_subnet.devnets.id
    securityGroupIds = [aws_security_group.devnet_nodes.id]
    keyName          = aws_key_pair.status_agent.key_name
    ipamPoolId       = data.aws_vpc_ipam_pool.owned.id
    dnsZoneId        = data.aws_route53_zone.networks.zone_id
    stateTable       = aws_dynamodb_table.managed_state.name
  }
}

output "operations" {
  description = "What the environments of dashpay/dash-network-go name in their variables (DASHNET_AWS_ROLE, DASHNET_ARTIFACT_BUCKET, DASHNET_STATE_TABLE)."
  value = {
    roles  = { for name, role in aws_iam_role.operations : name => role.arn }
    bucket = aws_s3_bucket.operations.bucket
    table  = aws_dynamodb_table.managed_state.name
  }
}
