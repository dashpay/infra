# What starts the publisher: one state machine, started by a daily schedule
# and by the release workflow of dashpay/platform.
#
# Nothing else may start the CodeBuild project. StartBuild lets its caller
# replace the build's commands, and a caller who can do that can read the
# signing key. The state machine passes one value, the release tag, and the
# publisher refuses anything that is not a tag.

locals {
  publish_task = {
    Type           = "Task"
    Resource       = "arn:aws:states:::codebuild:startBuild.sync"
    TimeoutSeconds = 3600
    End            = true

    # Another run holds the project (publisher.tf, concurrent_build_limit).
    # Wait for it: up to an hour, which is longer than a run may take.
    Retry = [{
      ErrorEquals     = ["CodeBuild.AccountLimitExceededException"]
      IntervalSeconds = 60
      MaxAttempts     = 60
      BackoffRate     = 1
    }]
  }
}

resource "aws_sfn_state_machine" "publish" {
  name     = "dashmate-apt-publish"
  role_arn = aws_iam_role.state_machine.arn

  definition = jsonencode({
    Comment = "Publish the dashmate apt repository. Input {\"tag\": \"v5.1.0\"} adds a release; {} only re-signs and moves releases signed since into stable."
    StartAt = "HasTag"
    States = {
      HasTag = {
        Type    = "Choice"
        Choices = [{ Variable = "$.tag", IsString = true, Next = "PublishRelease" }]
        Default = "Refresh"
      }

      PublishRelease = merge(local.publish_task, {
        Parameters = {
          ProjectName = aws_codebuild_project.publisher.name
          EnvironmentVariablesOverride = [{
            Name      = "RELEASE_TAG"
            Type      = "PLAINTEXT"
            "Value.$" = "$.tag"
          }]
        }
      })

      Refresh = merge(local.publish_task, {
        Parameters = {
          ProjectName = aws_codebuild_project.publisher.name
        }
      })
    }
  })
}

data "aws_iam_policy_document" "state_machine_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

data "aws_iam_policy_document" "state_machine" {
  statement {
    sid       = "RunThePublisher"
    actions   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.publisher.arn]
  }

  # How Step Functions learns that a build ended: a rule it manages itself.
  statement {
    sid       = "WaitForTheBuild"
    actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = ["arn:aws:events:${local.region}:${local.account}:rule/StepFunctionsGetEventForCodeBuildStartBuildRule"]
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "dashmate-apt-publish-state-machine"
  description        = "The state machine that starts the dashmate apt publisher"
  assume_role_policy = data.aws_iam_policy_document.state_machine_trust.json
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "run-the-publisher"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine.json
}

# --- every day ---------------------------------------------------------------
#
# Release carries Valid-Until, ten days ahead. This run signs it again each
# day, so nine runs in a row have to fail before a host sees an expired
# repository.

data "aws_iam_policy_document" "schedule_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

data "aws_iam_policy_document" "start_execution" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.publish.arn]
  }
}

resource "aws_iam_role" "schedule" {
  name               = "dashmate-apt-publish-schedule"
  description        = "The daily schedule that re-signs the dashmate apt repository"
  assume_role_policy = data.aws_iam_policy_document.schedule_trust.json
}

resource "aws_iam_role_policy" "schedule" {
  name   = "start-the-state-machine"
  role   = aws_iam_role.schedule.id
  policy = data.aws_iam_policy_document.start_execution.json
}

resource "aws_scheduler_schedule" "daily" {
  name        = "dashmate-apt-publish-daily"
  description = "Re-signs the dashmate apt repository before Valid-Until runs out"

  schedule_expression          = "cron(17 5 * * ? *)"
  schedule_expression_timezone = "UTC"

  # Off until the repository has a key: README.md, "The key".
  state = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.publish.arn
    role_arn = aws_iam_role.schedule.arn
    input    = jsonencode({})
  }
}

variable "schedule_enabled" {
  description = "Whether the daily run is on. Turn it on when the archive keyring is committed and the signing subkey is in Secrets Manager; before that every run is refused."
  type        = bool
  default     = false
}

# --- on a release ---------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

variable "release_environment" {
  description = "The environment of dashpay/platform whose jobs may ask for a release to be published. Restrict it to v* tags there: that restriction is what keeps branches out."
  type        = string
  default     = "dashmate-apt-publish"
}

data "aws_iam_policy_document" "release" {
  statement {
    sid       = "AskForARelease"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.publish.arn]
  }

  statement {
    sid       = "SeeHowItEnded"
    actions   = ["states:DescribeExecution"]
    resources = ["arn:aws:states:${local.region}:${local.account}:execution:${aws_sfn_state_machine.publish.name}:*"]
  }
}

module "release_role" {
  source = "../../modules/github-oidc-role"

  name              = "dashmate-apt-release"
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects          = ["repo:dashpay/platform:environment:${var.release_environment}"]
  policy_json       = data.aws_iam_policy_document.release.json
}

output "repository" {
  description = "What the platform side and operators need to know."
  value = {
    url               = "https://${local.hostname}/${local.prefix}"
    bucket            = aws_s3_bucket.repository.id
    distribution_id   = aws_cloudfront_distribution.repository.id
    release_role_arn  = module.release_role.arn
    state_machine_arn = aws_sfn_state_machine.publish.arn
    publisher_project = aws_codebuild_project.publisher.name
    publisher_log     = aws_cloudwatch_log_group.publisher.name
    signing_secret    = aws_secretsmanager_secret.signing_key.name
  }
}
