# The status host's role, `dash-status-server`.
#
# The console's agent container is the process that is meant to use it.
# Nothing enforces that: the instance allows two metadata hops (host.tf), so
# every container on the host, the public web container included, can reach
# the metadata service and read this role's credentials (checked 2026-11-21:
# all five containers get an IMDSv2 token). The host has no firewall rule
# against it and the containers' network is defined in `dashpay/status`, not
# here. Until that is fixed there, treat a compromise of any container on the
# host as a compromise of this role. The role is what lets the agent find
# hosts, get its SSH key onto them, keep the engine's records, and build and
# remove console devnets. It is the console's whole reach into AWS, so it is
# written out in full here, exactly as it was found on 2026-11-20.
#
# The two policies come from `dashpay/status`: `status-agent` was put on the
# role by hand as the console grew, and `status-inventory` is
# `deploy/iam/status-inventory.json` there (the live copy has the same
# actions split over three statements). Neither is applied by the console's
# deploy; a change in that repository has to be made here too.

resource "aws_iam_role" "status_server" {
  name        = "dash-status-server"
  description = "status.testnet.networks.dash.org agent: discovery, SSH key provisioning, dashnet journal"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "status_server" {
  name = "dash-status-server"
  role = aws_iam_role.status_server.name
}

locals {
  # Shorthand for the ARNs the agent's policy is scoped to.
  ec2_arn = "arn:aws:ec2:${local.region}:${local.account_id}"

  # The engine keys its table by "<account>/<region>/<network>".
  journal_key_prefix = "${local.account_id}/${local.region}"

  # Everything dash-network-go creates carries this tag, and the agent may
  # only stop, change or delete what carries it.
  devnet_owned = {
    StringEquals = { "aws:ResourceTag/dashnet:managed-by" = "dash-network-go" }
  }
}

resource "aws_iam_role_policy" "status_agent" {
  name = "status-agent"
  role = aws_iam_role.status_server.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # --- Every network: find the hosts and reach them ---------------------

      {
        Sid       = "Discover"
        Effect    = "Allow"
        Action    = ["ec2:DescribeInstances", "ec2:GetConsoleOutput"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },

      # The agent pushes its SSH key through EC2 Instance Connect to a host
      # that does not have it yet. Console devnets are not in this list:
      # their hosts are launched with the key pair `dash-status-agent`.
      {
        Sid      = "InstanceConnect"
        Effect   = "Allow"
        Action   = "ec2-instance-connect:SendSSHPublicKey"
        Resource = "${local.ec2_arn}:instance/*"
        Condition = {
          StringEquals = { "ec2:osuser" = "ubuntu" }
          "ForAnyValue:StringEquals" = {
            "aws:ResourceTag/DashNetwork" = ["testnet", "devnet-moutai", "mainnet-support"]
          }
        }
      },

      # One mainnet host by id: dn-mainnet-support-seed-1.
      {
        Sid       = "InstanceConnectMainnetSeed"
        Effect    = "Allow"
        Action    = "ec2-instance-connect:SendSSHPublicKey"
        Resource  = "${local.ec2_arn}:instance/i-000b136e936bcf347"
        Condition = { StringEquals = { "ec2:osuser" = "ubuntu" } }
      },

      # --- The engine's records (state-table.tf) ----------------------------

      {
        Sid      = "JournalTable"
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeTable"]
        Resource = aws_dynamodb_table.managed_state.arn
      },
      {
        Sid      = "JournalItems"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.managed_state.arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "dynamodb:LeadingKeys" = [
              "${local.journal_key_prefix}/testnet",
              "${local.journal_key_prefix}/devnet-moutai",
            ]
          }
        }
      },
      {
        Sid      = "DevnetJournal"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.managed_state.arn
        Condition = {
          "ForAllValues:StringLike" = {
            "dynamodb:LeadingKeys" = ["${local.journal_key_prefix}/devnet-*"]
          }
        }
      },

      # --- Console devnets: build ------------------------------------------

      {
        Sid    = "DevnetDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeKeyPairs",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeAddresses",
          "ec2:DescribeIpamPools",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcs",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
      {
        Sid      = "UbuntuAmiLookup"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.region}::parameter/aws/service/canonical/ubuntu/server/*"
      },

      # Instances may be launched only into the devnet subnet and with the
      # devnet security group (devnets.tf). This is what keeps the console
      # from launching anything anywhere else. The key pair is limited only
      # when the request names one: the agent's key pair is the only one
      # allowed, but a launch with no KeyName passes this statement too.
      {
        Sid    = "DevnetLaunchPlacement"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          aws_subnet.devnets.arn,
          aws_security_group.devnet_nodes.arn,
          aws_key_pair.status_agent.arn,
          "arn:aws:ec2:${local.region}::image/*",
          "${local.ec2_arn}:network-interface/*",
        ]
      },
      {
        Sid       = "DevnetLaunchOwned"
        Effect    = "Allow"
        Action    = "ec2:RunInstances"
        Resource  = ["${local.ec2_arn}:instance/*", "${local.ec2_arn}:volume/*"]
        Condition = { StringEquals = { "aws:RequestTag/dashnet:managed-by" = "dash-network-go" } }
      },
      {
        Sid    = "DevnetTagOnCreate"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "${local.ec2_arn}:instance/*",
          "${local.ec2_arn}:volume/*",
          "${local.ec2_arn}:network-interface/*",
          "${local.ec2_arn}:elastic-ip/*",
        ]
        Condition = { StringEquals = { "ec2:CreateAction" = ["RunInstances", "AllocateAddress"] } }
      },
      {
        Sid    = "DevnetTagOwned"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "${local.ec2_arn}:instance/*",
          "${local.ec2_arn}:volume/*",
          "${local.ec2_arn}:elastic-ip/*",
        ]
        Condition = local.devnet_owned
      },

      # --- Console devnets: addresses from the owned pool -------------------

      {
        Sid      = "DevnetIpamAllocation"
        Effect   = "Allow"
        Action   = ["ec2:AllocateIpamPoolCidr", "ec2:ReleaseIpamPoolAllocation", "ec2:GetIpamPoolAllocations"]
        Resource = data.aws_vpc_ipam_pool.owned.arn
      },
      # An address must carry the ownership tag from the moment it exists, so
      # the agent can always release what it allocated. dash-network-go sends
      # the tags in AllocateAddress itself (internal/provision/ipam.go).
      #
      # The pool is not limited here: AllocateAddress could also take an
      # address from Amazon's pool. dash-network-go only ever asks the owned
      # IPAM pool (IpamPoolId); the statement above is what limits the CIDR
      # calls to that pool.
      {
        Sid       = "DevnetAddresses"
        Effect    = "Allow"
        Action    = ["ec2:AllocateAddress"]
        Resource  = ["*"]
        Condition = { StringEquals = { "aws:RequestTag/dashnet:managed-by" = "dash-network-go" } }
      },
      {
        Sid       = "DevnetAddressesOwned"
        Effect    = "Allow"
        Action    = ["ec2:AssociateAddress", "ec2:DisassociateAddress", "ec2:ReleaseAddress"]
        Resource  = "*"
        Condition = local.devnet_owned
      },
      # The instance an owned address goes to must be a console devnet node,
      # so the agent cannot move an address onto anything else. dash-network-go
      # associates by instance id with AllowReassociation false.
      {
        Sid       = "DevnetAssociateTarget"
        Effect    = "Allow"
        Action    = ["ec2:AssociateAddress"]
        Resource  = ["${local.ec2_arn}:instance/*"]
        Condition = local.devnet_owned
      },
      # The instance's network interface is part of the same request. The
      # engine does not tag interfaces, so they cannot be limited by tag; an
      # association by interface id alone is therefore still possible.
      {
        Sid      = "DevnetAssociateInterface"
        Effect   = "Allow"
        Action   = ["ec2:AssociateAddress"]
        Resource = ["${local.ec2_arn}:network-interface/*"]
      },

      # --- Console devnets: remove -----------------------------------------

      {
        Sid       = "DevnetTeardownOwned"
        Effect    = "Allow"
        Action    = ["ec2:TerminateInstances", "ec2:StopInstances", "ec2:StartInstances", "ec2:DeleteVolume"]
        Resource  = ["${local.ec2_arn}:instance/*", "${local.ec2_arn}:volume/*"]
        Condition = local.devnet_owned
      },

      # --- Console devnets: names in networks.dash.org ----------------------

      {
        Sid      = "DevnetDnsRead"
        Effect   = "Allow"
        Action   = ["route53:GetChange", "route53:ListResourceRecordSets", "route53:GetHostedZone"]
        Resource = [data.aws_route53_zone.networks.arn, "arn:aws:route53:::change/*"]
      },

      # A records for a devnet's service names, and nothing else in the zone.
      {
        Sid      = "DevnetDnsWrite"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.networks.arn
        Condition = {
          "ForAllValues:StringLike" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [
              "insight.*.networks.dash.org",
              "quorums.*.networks.dash.org",
              "explorer.*.networks.dash.org",
              "faucet.*.networks.dash.org",
              "dapi.*.networks.dash.org",
              "seed-*.*.networks.dash.org",
            ]
          }
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsRecordTypes" = ["A"]
          }
        }
      },

      # Whatever the statement above would allow, the names of testnet,
      # mainnet and Moutai stay out of the console's reach. This also covers
      # the console's own name, status.testnet.networks.dash.org (dns.tf).
      {
        Sid      = "DevnetDnsProtectExisting"
        Effect   = "Deny"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [
              "*.testnet.networks.dash.org",
              "*.mainnet.networks.dash.org",
              "*.mainnet-support.networks.dash.org",
              "*.moutai.networks.dash.org",
              "*.*.*.networks.dash.org",
            ]
          }
        }
      },
    ]
  })
}

# What the console's AWS page (`/aws`) and its incident checks read, in every
# region. Read-only. Cost Explorer is billed per request ($0.01); the agent
# asks twice a day.
resource "aws_iam_role_policy" "status_inventory" {
  name = "status-inventory"
  role = aws_iam_role.status_server.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InventoryReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:DescribeRegions",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeVolumes",
          "ec2:DescribeAddresses",
          "ec2:DescribeNatGateways",
          "ec2:DescribeSnapshots",
          "elasticloadbalancing:DescribeLoadBalancers",
          "cloudfront:ListDistributions",
          "lambda:ListFunctions",
          "dynamodb:ListTables",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "s3:ListAllMyBuckets",
          "ce:GetCostAndUsage",
          "ce:GetCostForecast",
        ]
        Resource = "*"
      },
      {
        Sid      = "IncidentRuntimeHealthReadOnly"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstanceStatus", "cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      {
        Sid      = "IncidentScalingSemanticsReadOnly"
        Effect   = "Allow"
        Action   = ["application-autoscaling:DescribeScalingPolicies"]
        Resource = "*"
      },
    ]
  })
}
