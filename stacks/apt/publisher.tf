# The publisher: one CodeBuild project that holds the signing key and is the
# only thing that writes the repository. Its code is publisher/ in this
# directory. It runs the copy Terraform uploaded, by object version, so a
# change to the code reaches it through `terraform apply` and no other way.

resource "aws_s3_bucket" "publisher" {
  bucket = "dash-apt-publisher-${local.account}"
}

resource "aws_s3_bucket_versioning" "publisher" {
  bucket = aws_s3_bucket.publisher.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "publisher" {
  bucket = aws_s3_bucket.publisher.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "archive_file" "publisher" {
  type             = "zip"
  source_dir       = "${path.module}/publisher"
  output_path      = "${path.module}/.terraform/publisher.zip"
  output_file_mode = "0644"
  excludes         = ["tests/**", "**/__pycache__/**", "__pycache__/**"]
}

resource "aws_s3_object" "publisher" {
  bucket      = aws_s3_bucket.publisher.id
  key         = "publisher.zip"
  source      = data.archive_file.publisher.output_path
  source_hash = data.archive_file.publisher.output_base64sha256

  depends_on = [aws_s3_bucket_versioning.publisher]
}

# The online signing subkey. Terraform makes the container; the value is put
# there by hand when the key is made (README.md, "The key") and is never in
# this repository or in state.
resource "aws_secretsmanager_secret" "signing_key" {
  name        = "dashmate-apt/signing-key"
  description = "Signing subkey of the dashmate apt repository's archive key. Binary: gpg --export-secret-subkeys <subkey>!"
}

resource "aws_cloudwatch_log_group" "publisher" {
  name              = "/aws/codebuild/dashmate-apt-publish"
  retention_in_days = 365
}

data "aws_iam_policy_document" "publisher_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

data "aws_iam_policy_document" "publisher" {
  statement {
    sid       = "WriteItsLog"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.publisher.arn}:*"]
  }

  statement {
    sid       = "ReadItsOwnCode"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.publisher.arn}/${aws_s3_object.publisher.key}"]
  }

  statement {
    sid       = "ListTheRepository"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.repository.arn]
  }

  # No delete: the publisher adds and replaces, and a pool file is written
  # with If-None-Match, so it cannot replace one either.
  statement {
    sid       = "ReadAndWriteTheRepository"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.repository.arn}/${local.prefix}/*"]
  }

  statement {
    sid       = "ReadTheSigningKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.signing_key.arn]
  }
}

resource "aws_iam_role" "publisher" {
  name               = "dashmate-apt-publish"
  description        = "The CodeBuild job that signs and publishes the dashmate apt repository"
  assume_role_policy = data.aws_iam_policy_document.publisher_trust.json
}

resource "aws_iam_role_policy" "publisher" {
  name   = "publish"
  role   = aws_iam_role.publisher.id
  policy = data.aws_iam_policy_document.publisher.json
}

resource "aws_codebuild_project" "publisher" {
  name          = "dashmate-apt-publish"
  description   = "Signs and publishes the dashmate apt repository (stacks/apt in dashpay/infra)"
  service_role  = aws_iam_role.publisher.arn
  build_timeout = 30

  # One run at a time: two runs would each write an index without the
  # other's change. A second start is refused, and the state machine in
  # trigger.tf waits and tries again.
  concurrent_build_limit = 1

  source {
    type     = "S3"
    location = "${aws_s3_bucket.publisher.id}/${aws_s3_object.publisher.key}"

    # Nothing is installed: python3, gpg, dpkg-deb and the AWS CLI are in the
    # image, and the publisher uses the standard library only.
    buildspec = <<-YAML
      version: 0.2
      phases:
        build:
          commands:
            - python3 --version && gpg --version | head -n 1 && dpkg-deb --version | head -n 1 && aws --version
            - python3 publish.py
    YAML
  }

  source_version = aws_s3_object.publisher.version_id

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"

    environment_variable {
      name  = "REPO_BUCKET"
      value = aws_s3_bucket.repository.id
    }

    environment_variable {
      name  = "REPO_PREFIX"
      value = local.prefix
    }

    environment_variable {
      name  = "SIGNING_SECRET_ID"
      value = aws_secretsmanager_secret.signing_key.arn
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.publisher.name
    }
  }
}
