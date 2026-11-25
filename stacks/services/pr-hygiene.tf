# The PR Hygiene service (dashpay/infra#90): code in
# dashpay/stale_prs_are_bad, directory service/.

# The GitHub Actions OIDC provider already exists in this account and is
# shared with other roles, so it is looked up, not managed.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# The owned address range (68.67.122.0/24) as it is offered in us-west-2.
# Public hosts use it rather than Amazon-assigned addresses. The pool belongs
# to the account stack. An IPAM is read in its home region.
data "aws_vpc_ipam_pool" "owned" {
  region = "us-east-1"

  filter {
    name   = "description"
    values = ["byoip-us-west-2"]
  }
}

module "pr_hygiene" {
  source = "../../modules/pr-hygiene"

  hostname  = "pr-hygiene.${aws_route53_zone.services.name}"
  zone_id   = aws_route53_zone.services.zone_id
  vpc_id    = aws_vpc.services.id
  subnet_id = aws_subnet.services["a"].id

  ipam_pool_id = data.aws_vpc_ipam_pool.owned.id

  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  github_repository        = "dashpay/stale_prs_are_bad"
  github_environment       = "production"
}

output "pr_hygiene" {
  description = "What the service's repository and its operators need to know."
  value = {
    url             = module.pr_hygiene.url
    public_ip       = module.pr_hygiene.public_ip
    instance_id     = module.pr_hygiene.instance_id
    deploy_role_arn = module.pr_hygiene.deploy_role_arn
    ecr_repository  = module.pr_hygiene.ecr_repository_url
    deploy_document = module.pr_hygiene.deploy_document
    deploy_target   = module.pr_hygiene.deploy_target
    backup_bucket   = module.pr_hygiene.backup_bucket
    data_volume_id  = module.pr_hygiene.data_volume_id
  }
}
