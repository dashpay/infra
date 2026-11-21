# An IAM role that GitHub Actions jobs assume with their OIDC token, and
# nothing else can. The trust is pinned to exact `sub` values: no wildcards,
# so a role is never open to every branch or workflow of a repository.

variable "name" {
  description = "Role name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the account's token.actions.githubusercontent.com provider."
  type        = string
}

variable "subjects" {
  description = "Exact `sub` claims allowed to assume the role, e.g. repo:owner/name:environment:production."
  type        = list(string)

  validation {
    condition     = length(var.subjects) > 0 && alltrue([for s in var.subjects : !strcontains(s, "*") && !strcontains(s, "?")])
    error_message = "List at least one subject, and no wildcards."
  }
}

variable "policy_json" {
  description = "The role's permissions, as an IAM policy document."
  type        = string
}

variable "max_session_duration" {
  description = "Longest session, in seconds."
  type        = number
  default     = 3600
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
}

resource "aws_iam_role_policy" "this" {
  name   = var.name
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

output "arn" {
  value = aws_iam_role.this.arn
}

output "name" {
  value = aws_iam_role.this.name
}
