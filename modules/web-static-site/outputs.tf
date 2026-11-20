output "distribution_id" {
  description = "CLOUDFRONT_DISTRIBUTION_ID in the site's repository."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "What the host name points at. Where the zone is not in Route 53, a CNAME to this is made by hand."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "certificate_validation" {
  description = "The record ACM checks before it issues or renews the certificate. Where the zone is not in Route 53, it is made by hand."
  value       = local.validation
}

output "deploy_role_arn" {
  description = "AWS_ROLE_TO_ASSUME in the site's repository. Null for a site nothing deploys."
  value       = one(aws_iam_role.deploy[*].arn)
}
