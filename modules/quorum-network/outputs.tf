output "url" {
  description = "The public address of this network's quorum list."
  value       = "https://${local.hostname}"
}

output "core_instance_id" {
  value = aws_instance.core.id
}

output "core_private_ip" {
  value = aws_instance.core.private_ip
}

output "quorum_server_instance_id" {
  value = aws_instance.quorum_server.id
}

output "quorum_server_security_group_id" {
  description = "For a host that serves in place of this module's quorum server: it needs this group to be let in by the load balancer and by Core."
  value       = aws_security_group.quorum_server.id
}

output "serving_instance_id" {
  description = "The instance the load balancer sends this network's requests to."
  value       = aws_lb_target_group_attachment.quorum.target_id
}

output "efs_id" {
  value = aws_efs_file_system.core.id
}

output "distribution_id" {
  value = aws_cloudformation_stack.cdn.outputs["DistributionId"]
}
