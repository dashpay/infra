# How a new image gets onto the host.
#
# A job in the service's repository, running in a GitHub environment that
# only the protected branch can use, assumes the deploy role with its OIDC
# token. The role can do two things: push to one ECR repository, and run one
# SSM document on hosts tagged for this service. The document takes an image
# digest and nothing else, so the job has no shell on the host and holds no
# long-lived key.

resource "aws_ecr_repository" "this" {
  name                 = "${var.name}-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ssm_document" "deploy" {
  name            = "${var.name}-deploy"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Deploy one image of the PR Hygiene service, by digest. Goes back to the previous image if the new one does not become ready."
    parameters = {
      digest = {
        type           = "String"
        description    = "Digest of an image in the service's ECR repository."
        allowedPattern = "^sha256:[a-f0-9]{64}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deploy"
      inputs = {
        timeoutSeconds = "300"
        # The pattern above admits hex and a colon only; the script checks
        # it again.
        runCommand = ["/usr/local/sbin/pr-hygiene-deploy '{{ digest }}'"]
      }
    }]
  })

  tags = local.tags
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushTheImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.this.arn]
  }

  statement {
    sid       = "RunTheDeployDocument"
    actions   = ["ssm:SendCommand"]
    resources = [aws_ssm_document.deploy.arn]
  }

  statement {
    sid       = "OnThisServicesHostsOnly"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${local.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Service"
      values   = [var.name]
    }
  }

  # Reading a command's result cannot be limited to one command or host:
  # these actions take no resource. The role can therefore read the output
  # of other Run Command invocations in this account and region.
  statement {
    sid = "ReadTheResult"
    actions = [
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
    ]
    resources = ["*"]
  }
}

module "deploy_role" {
  source = "../github-oidc-role"

  name              = "${var.name}-deploy"
  oidc_provider_arn = var.github_oidc_provider_arn
  subjects          = ["repo:${var.github_repository}:environment:${var.github_environment}"]
  policy_json       = data.aws_iam_policy_document.deploy.json
}
