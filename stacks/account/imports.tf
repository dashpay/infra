# The import blocks that adopted what existed before this stack. They are
# inert once applied. To build the stack from nothing, delete this file.

# --- state bucket (us-east-1)

import {
  to = aws_s3_bucket.state
  id = "dash-terraform-state-854439639386@us-east-1"
}

import {
  to = aws_s3_bucket_versioning.state
  id = "dash-terraform-state-854439639386@us-east-1"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.state
  id = "dash-terraform-state-854439639386@us-east-1"
}

import {
  to = aws_s3_bucket_public_access_block.state
  id = "dash-terraform-state-854439639386@us-east-1"
}

import {
  to = aws_s3_bucket_ownership_controls.state
  id = "dash-terraform-state-854439639386@us-east-1"
}

# --- GitHub Actions identity provider

import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::854439639386:oidc-provider/token.actions.githubusercontent.com"
}

# --- account settings

import {
  to = aws_iam_account_alias.this
  id = "dashdev"
}

import {
  to = aws_iam_account_password_policy.this
  id = "iam-account-password-policy"
}

# --- users

# Pinned to what existed at adoption (2026-11-20). Driven by local.users itself,
# a user or attachment added later would get an import of something that does
# not exist yet, and the plan would fail instead of creating it.
locals {
  adopted_users = ["daniel", "quantum", "vivek", "gitlab-runner"]
  adopted_user_policy_attachments = [
    "daniel/AdministratorAccess",
    "quantum/AdministratorAccess",
    "gitlab-runner/AdministratorAccess",
    "gitlab-runner/AmazonEC2FullAccess",
    "gitlab-runner/AmazonS3FullAccess",
  ]
}

import {
  for_each = toset(local.adopted_users)
  to       = aws_iam_user.this[each.key]
  id       = each.key
}

import {
  for_each = toset(local.adopted_user_policy_attachments)
  to       = aws_iam_user_policy_attachment.this[each.key]
  id       = "${split("/", each.key)[0]}/arn:aws:iam::aws:policy/${split("/", each.key)[1]}"
}

import {
  to = aws_iam_user_policy.vivek_offboarding_deny
  id = "vivek:OffboardingDenyAll20260908"
}

import {
  to = aws_iam_user_policy.gitlab_runner_ecr_login
  id = "gitlab-runner:ECR_login_policy"
}

import {
  to = aws_iam_user_policy.gitlab_runner_s3_cache
  id = "gitlab-runner:s3_cache_Access"
}

# --- group

import {
  to = aws_iam_group.kops
  id = "kops"
}

import {
  for_each = toset([
    "AmazonEC2FullAccess",
    "AmazonRoute53FullAccess",
    "AmazonS3FullAccess",
    "AmazonVPCFullAccess",
    "IAMFullAccess",
  ])
  to = aws_iam_group_policy_attachment.kops[each.key]
  id = "kops/arn:aws:iam::aws:policy/${each.key}"
}

# --- IPAM and the owned address block (managed through us-east-1)

import {
  to = aws_vpc_ipam.org
  id = "ipam-05f50613740bd8f80@us-east-1"
}

import {
  to = aws_vpc_ipam_pool.top_level
  id = "ipam-pool-0aea2deaf4d7e0c04@us-east-1"
}

import {
  to = aws_vpc_ipam_pool_cidr.top_level
  id = "68.67.122.0/24_ipam-pool-0aea2deaf4d7e0c04@us-east-1"
}

import {
  to = aws_vpc_ipam_pool.us_west_2
  id = "ipam-pool-0de83ed8bba5f9b48@us-east-1"
}

import {
  to = aws_vpc_ipam_pool_cidr.us_west_2
  id = "68.67.122.0/24_ipam-pool-0de83ed8bba5f9b48@us-east-1"
}
