output "bastion_public_ip" {
  description = "Where to SSH to reach the private hosts. Changes if the bastion is stopped and started."
  value       = aws_instance.bastion.public_ip
}

output "nat_public_ip" {
  description = "The address the private hosts' outgoing traffic comes from."
  value       = aws_eip.nat.public_ip
}

output "load_balancer_dns_name" {
  description = "The shared load balancer. The faucet's DNS record and both CloudFront distributions point here."
  value       = aws_lb.main.dns_name
}

# Per network: the public address, the hosts, the file system, the
# distribution, and which instance the load balancer sends requests to.
output "testnet" {
  value = module.testnet
}

output "mainnet" {
  value = module.mainnet
}
