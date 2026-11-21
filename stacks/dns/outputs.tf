output "name_servers" {
  description = "Each zone's name servers: what Cloudflare (NS records in dash.org) or the domain's registrar must point at."
  value       = { for name, zone in aws_route53_zone.this : name => zone.name_servers }
}
