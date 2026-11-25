# The role the site's repository publishes with. A GitHub Actions job
# assumes it with its OIDC token and holds no long-lived key. It can write
# under the site's own prefix and invalidate the site's own distribution,
# and nothing else.
#
# The trust accepts every workflow run of the repository, whatever the
# branch, tag or environment: that is how the roles were made on 2026-11-20.
# modules/github-oidc-role pins exact subjects and is the stricter choice;
# moving to it means giving each repository a protected environment first.

locals {
  deploys = var.deploy_repository != null
}

resource "aws_iam_role" "deploy" {
  count = local.deploys ? 1 : 0

  name        = "github-deploy-static-site-${var.key}"
  description = coalesce(var.deploy_role_description, "GitHub Actions deploy of ${var.hostname} from ${var.deploy_repository} (dashpay/infra#19)")

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.deploy_repository}:*" }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "deploy" {
  count = local.deploys ? 1 : 0

  name = "deploy"
  role = aws_iam_role.deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListOwnPrefix"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = var.bucket.arn
        Condition = { StringLike = { "s3:prefix" = [var.key, "${var.key}/*"] } }
      },
      {
        # PutObjectAcl because the workflows upload with `--acl private`.
        Sid      = "WriteOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:PutObjectAcl", "s3:DeleteObject"]
        Resource = "${var.bucket.arn}/${var.key}/*"
      },
      {
        Sid      = "InvalidateOwnDistribution"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
        Resource = aws_cloudfront_distribution.this.arn
      },
    ]
  })
}
