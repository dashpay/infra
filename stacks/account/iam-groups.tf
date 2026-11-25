# The account's only IAM group. It dates from 2018 (a kops Kubernetes
# cluster) and has no members. Adopted as it was found.

resource "aws_iam_group" "kops" {
  name = "kops"
}

resource "aws_iam_group_policy_attachment" "kops" {
  for_each = toset([
    "AmazonEC2FullAccess",
    "AmazonRoute53FullAccess",
    "AmazonS3FullAccess",
    "AmazonVPCFullAccess",
    "IAMFullAccess",
  ])

  group      = aws_iam_group.kops.name
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
}
