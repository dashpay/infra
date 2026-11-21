# IAM users that are a person or CI, with what each may do.
#
# Managed here: the user, the AWS-managed policies attached to it, and its
# inline policies. Not managed here, on purpose: access keys, console
# passwords and MFA devices. They are secrets or belong to the person, and
# nothing secret may reach the state. They are made by hand (README).
#
# Service users (`backup-wp2021`, `backup-forum2023`, `wordpress-media`) are
# in the stacks of the things they serve.
#
# Removing a user from this map deletes the user. AWS refuses that while the
# user still has access keys, a password or an MFA device: remove those by
# hand first.

locals {
  users = {
    # Head of infrastructure. Console password with MFA, and access keys.
    # This is also the user this repository is applied with, so a mistake in
    # this entry can lock Terraform out of the account.
    daniel = {
      aws_managed_policies = ["AdministratorAccess"]
    }

    # Platform maintainer. Console password, no MFA device.
    quantum = {
      aws_managed_policies = ["AdministratorAccess"]
    }

    # Left the company on 2026-09-08. The user was kept, with no password
    # and no keys, and with one inline policy that denies everything
    # (below).
    vivek = {
      aws_managed_policies = []
    }

    # CI. Its access key is used to log in to ECR in eu-west-1. It holds
    # far more than that needs; adopted as it was found.
    gitlab-runner = {
      aws_managed_policies = [
        "AdministratorAccess",
        "AmazonEC2FullAccess",
        "AmazonS3FullAccess",
      ]
    }
  }

  user_policy_attachments = merge([
    for user, u in local.users : {
      for policy in u.aws_managed_policies : "${user}/${policy}" => {
        user   = user
        policy = policy
      }
    }
  ]...)
}

resource "aws_iam_user" "this" {
  for_each = local.users

  name = each.key

  lifecycle {
    # The IAM console keeps the description of an access key as a tag on the
    # user, with the key's id as the tag's name. Access keys are not managed
    # here, so neither are their descriptions: writing them down would put
    # key ids in this repository, and leaving them out would delete them.
    ignore_changes = [tags]
  }
}

resource "aws_iam_user_policy_attachment" "this" {
  for_each = local.user_policy_attachments

  user       = aws_iam_user.this[each.value.user].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value.policy}"
}

# --- vivek

data "aws_iam_policy_document" "vivek_offboarding_deny" {
  statement {
    sid       = "DenyAllDuringOffboarding"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "vivek_offboarding_deny" {
  name   = "OffboardingDenyAll20260908"
  user   = aws_iam_user.this["vivek"].name
  policy = data.aws_iam_policy_document.vivek_offboarding_deny.json
}

# --- gitlab-runner

# Log in to ECR and push or pull any repository in eu-west-1. This is the
# only thing CI is known to use this user for.
data "aws_iam_policy_document" "gitlab_runner_ecr_login" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = ["arn:aws:ecr:eu-west-1:854439639386:repository/*"]
  }
}

resource "aws_iam_user_policy" "gitlab_runner_ecr_login" {
  name   = "ECR_login_policy"
  user   = aws_iam_user.this["gitlab-runner"].name
  policy = data.aws_iam_policy_document.gitlab_runner_ecr_login.json
}

# A build cache bucket. No bucket of this name exists in the account any
# more; the policy is kept as it was found.
data "aws_iam_policy_document" "gitlab_runner_s3_cache" {
  statement {
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
    ]
    resources = [
      "arn:aws:s3:::dash-gitlab-runner-cache",
      "arn:aws:s3:::dash-gitlab-runner-cache/*",
    ]
  }
}

resource "aws_iam_user_policy" "gitlab_runner_s3_cache" {
  name   = "s3_cache_Access"
  user   = aws_iam_user.this["gitlab-runner"].name
  policy = data.aws_iam_policy_document.gitlab_runner_s3_cache.json
}

output "iam_users" {
  description = "People and CI users, with the AWS-managed policies each holds."
  value       = { for name, u in local.users : name => u.aws_managed_policies }
}
