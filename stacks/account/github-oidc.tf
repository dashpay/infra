# The account's GitHub Actions identity provider. Every role that a GitHub
# workflow assumes trusts it: the status console's operations roles, the
# static-site deploy roles, `pr-hygiene-deploy`. Without it every one of
# those deploys stops.
#
# Other stacks do not take its ARN from here. They look it up:
#
#   data "aws_iam_openid_connect_provider" "github" {
#     url = "https://token.actions.githubusercontent.com"
#   }
#
# An account can hold only one provider for this URL, and its ARN is made of
# the account id and the URL, so a provider that is recreated has the same
# ARN and the roles' trust policies stay valid.
#
# It was created in 2023 by the GitHub runner stack (`multi-runner`), which
# nobody applies any more. The `Project` tag is from then and is kept as it
# was found.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list: AWS checks GitHub's certificate against its own list
  # of authorities and does not use one. The provider that exists carries
  # the runner stack's placeholder (forty f's), which is left alone.

  tags = { Project = "multi-runner" }

  lifecycle {
    prevent_destroy = true
  }
}

output "github_oidc_provider_arn" {
  description = "The GitHub Actions identity provider that deploy roles trust."
  value       = aws_iam_openid_connect_provider.github.arn
}
