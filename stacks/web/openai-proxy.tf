# The OpenAI proxy behind dashpay.io.
#
# The data-contract creator at dashpay.io runs in the visitor's browser and
# must not hold the OpenAI key. It posts its request to this function's
# public URL; the function adds the key and passes the request on to
# api.openai.com. The site's source names the URL (src/services/openai.rs in
# dashpay/data-contract-creator), so a new URL means a new build of the site.
#
# The source is openai-proxy/index.mjs. It needs no packages: the Node.js
# runtime brings the AWS SDK.

locals {
  openai_proxy_name = "dashpay-openai-api-proxy"

  # A SecureString holding the OpenAI key. It is named here and never read:
  # the function fetches it when it starts. Terraform does not manage it, so
  # the key stays out of the state (README.md says how it gets there).
  openai_key_parameter = "/grovedb-site/openai-key"

  openai_proxy_tags = {
    Project = "dashpay-io"
    Issue   = "dashpay/infra/19"
  }
}

data "aws_region" "current" {}

# The zip goes under .terraform/, which git ignores. The fixed file mode
# makes the zip, and so its hash, the same on Windows and Linux.
data "archive_file" "openai_proxy" {
  type             = "zip"
  source_file      = "${path.module}/openai-proxy/index.mjs"
  output_path      = "${path.module}/.terraform/openai-proxy.zip"
  output_file_mode = "0644"
}

resource "aws_lambda_function" "openai_proxy" {
  function_name = local.openai_proxy_name
  description   = "OpenAI proxy for the dashpay.io data-contract creator (moved from dashevo)"
  role          = aws_iam_role.openai_proxy.arn

  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.openai_proxy.output_path
  source_code_hash = data.archive_file.openai_proxy.output_base64sha256

  # Seconds. The limit the function had in the dashevo account.
  timeout = 120

  environment {
    variables = {
      SSM_OPENAI_AUTHORIZATION_PARAMETER = local.openai_key_parameter
    }
  }

  tags = local.openai_proxy_tags

  # The log group first, or the function's first call makes its own.
  depends_on = [aws_cloudwatch_log_group.openai_proxy, aws_iam_role_policy.openai_proxy]

  # The code is the zip built from openai-proxy/. Until 2026-11-21 the
  # function ran the Serverless Framework package copied from dashevo and
  # this resource ignored the code; the first change to index.mjs replaced it.
}

# Anyone may call the URL: it has no sign-in. CORS only tells browsers that
# pages of dashpay.io alone may read the answer; it does not stop a caller
# that is not a browser.
resource "aws_lambda_function_url" "openai_proxy" {
  function_name      = aws_lambda_function.openai_proxy.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["https://dashpay.io"]
    allow_methods = ["POST"]
    allow_headers = ["content-type"]
  }
}

# A public function URL needs both of these permissions.
resource "aws_lambda_permission" "openai_proxy_url" {
  statement_id           = "public-url"
  function_name          = aws_lambda_function.openai_proxy.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

# As it was made, this one is not limited to calls that come through the
# URL (`invoked_via_function_url`), so another AWS account can also invoke
# the function through the Lambda API. The URL is public anyway.
resource "aws_lambda_permission" "openai_proxy_invoke" {
  statement_id  = "public-url-invoke"
  function_name = aws_lambda_function.openai_proxy.function_name
  action        = "lambda:InvokeFunction"
  principal     = "*"
}

# The function logs every request and every answer in full, and nothing
# expires.
resource "aws_cloudwatch_log_group" "openai_proxy" {
  name = "/aws/lambda/${local.openai_proxy_name}"
}

resource "aws_iam_role" "openai_proxy" {
  name        = local.openai_proxy_name
  description = "OpenAI proxy for dashpay.io (dashpay/infra#19)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.openai_proxy_tags
}

# Write its own log, read the one parameter.
resource "aws_iam_role_policy" "openai_proxy" {
  name = "proxy"
  role = aws_iam_role.openai_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.openai_proxy.arn}*"
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.openai_key_parameter}"
      },
    ]
  })
}
