# The operations roles: `dash-status-testnet-operations` and
# `dash-status-devnet-moutai-operations`.
#
# They are assumed by GitHub Actions, not by the status host: the workflow
# "Reviewed console operation" (`console-operation.yml`) in
# `dashpay/dash-network-go` runs one reviewed `dashnet` operation for one
# network, under the repository environment named in the role's trust. It
# reads the request from the operations bucket and writes the result back
# (operations-bucket.tf), and records its progress in the engine's table
# under that network's key only.
#
# That was how the console ran operations when it was set up, on
# 2026-09-28. Both roles were last used that day. Since then the agent on
# the status host runs `dashnet` itself, with the host's role.
#
# Each role is one network for the engine's table items and the bucket's
# objects. Not for EC2 reads: ec2:DescribeInstances is limited by region
# only, so either role can list every instance of every network in the
# region. Do not treat these roles as a network boundary for what they can
# see. They are not built with
# modules/github-oidc-role: these carry a policy name of their own and are
# adopted as they are.

locals {
  operations_roles = {
    # Testnet.
    "dash-status-testnet-operations" = {
      network     = "testnet"
      environment = "testnet-operations"
    }

    # LEFTOVER. Moutai was destroyed on 2026-10-01 and no host carries its
    # tag. The role can do nothing useful; it is adopted as found so that
    # removing it is a reviewed change here and not a forgotten one. The
    # environment `devnet-operations` that it trusts is used by every devnet
    # workflow of the repository.
    "dash-status-devnet-moutai-operations" = {
      network     = "devnet-moutai"
      environment = "devnet-operations"
    }
  }

  # GitHub's `sub` claim in the form that names the organisation and the
  # repository by their numeric ids as well as by name, so a repository that
  # is renamed, or another one later given the same name, does not match.
  dashnet_repository_subject = "repo:dashpay@11511719/dash-network-go@1384209245"
}

resource "aws_iam_role" "operations" {
  for_each = local.operations_roles

  name                 = each.key
  max_session_duration = 7200


  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${local.dashnet_repository_subject}:environment:${each.value.environment}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "operations" {
  for_each = local.operations_roles

  name = "exact-network-operations"
  role = aws_iam_role.operations[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["ec2:DescribeInstances"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeTable"]
        Resource = aws_dynamodb_table.managed_state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.managed_state.arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "dynamodb:LeadingKeys" = ["${local.journal_key_prefix}/${each.value.network}"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.operations.arn}/managed/${each.value.network}/requests/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.operations.arn}/managed/${each.value.network}/results/*"
      },
    ]
  })
}
