output "url" {
  description = "The service's public URL: PR_HYGIENE_SERVICE_URL in the service's repository."
  value       = local.url
}

output "public_ip" {
  value = aws_eip.this.public_ip
}

output "instance_id" {
  value = aws_instance.this.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "deploy_role_arn" {
  description = "The role the deploy job assumes: PR_HYGIENE_DEPLOY_ROLE_ARN in the service's repository."
  value       = module.deploy_role.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "deploy_document" {
  value = aws_ssm_document.deploy.name
}

output "deploy_target" {
  description = "The --targets value for ssm send-command."
  value       = "Key=tag:Service,Values=${var.name}"
}

output "backup_bucket" {
  value = aws_s3_bucket.backup.bucket
}
