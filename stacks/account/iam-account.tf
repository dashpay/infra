# Settings of the account itself.

# The name in the console sign-in address: https://dashdev.signin.aws.amazon.com/console
resource "aws_iam_account_alias" "this" {
  account_alias = "dashdev"
}

# The rule for console passwords of IAM users, adopted as it was found: eight
# characters and nothing else required, no expiry, no reuse check. Two users
# have a console password (see iam-users.tf).
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 8
  require_lowercase_characters   = false
  require_uppercase_characters   = false
  require_numbers                = false
  require_symbols                = false
  allow_users_to_change_password = true
}
