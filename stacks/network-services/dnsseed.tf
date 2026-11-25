# The DNS seeders: where a new Dash node asks for its first peers.
#
# Each is one small host running one container (nmarley/dnsseed) that
# crawls the network and answers DNS on UDP 53 with addresses of reachable
# nodes. It keeps nothing worth saving: a new seeder has a full list again
# within minutes of starting.
#
# The public names are in the Cloudflare zone dash.org and are not managed
# here. Mainnet: dnsseed.dash.org is delegated (NS) to seed.dash.org, an A
# record for the mainnet seeder's address. Testnet: test-dnsseed.dash.org
# and test-seed.dash.org in the same way. So the addresses must not change:
# they are Elastic IPs with prevent_destroy, and the hosts behind them can
# be replaced freely.
#
# There is no SSH: use SSM Session Manager.

locals {
  dnsseed_image = "nmarley/dnsseed:0.1.6-alpine"

  # zone: the two seeders are in different zones on purpose.
  # arguments: -h the name the seeder answers for, -n its own name as that
  # zone's name server, -m the zone's contact address.
  dnsseeds = {
    mainnet = {
      zone      = "us-west-2c"
      arguments = ["-h", "dnsseed.dash.org", "-n", "seed.dash.org", "-m", "dns.dash.org"]
    }
    testnet = {
      zone      = "us-west-2a"
      arguments = ["-h", "test-dnsseed.dash.org", "-n", "test-seed.dash.org", "-m", "dns.dash.org", "--testnet"]
    }
  }

  dnsseed_tags = {
    Project = "dnsseed"
    Issue   = "dashpay/infra/19"
  }
}

# Canonical's current Ubuntu 24.04 ARM64 image. Read when a seeder is
# created only (see ignore_changes below).
data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# --- Shared by both seeders ----------------------------------------------

# The hosts' role allows SSM and nothing else.
resource "aws_iam_role" "dnsseed" {
  name        = "dnsseed-ssm"
  description = "DNS seeder instances: SSM access only (dashpay/infra#19)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.dnsseed_tags
}

resource "aws_iam_role_policy_attachment" "dnsseed_ssm" {
  role       = aws_iam_role.dnsseed.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dnsseed" {
  name = "dnsseed-ssm"
  role = aws_iam_role.dnsseed.name
}

resource "aws_security_group" "dnsseed" {
  name        = "dnsseed"
  description = "Dash DNS seeders: DNS in, no SSH (use SSM)"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(local.dnsseed_tags, { Name = "dnsseed" })
}

# UDP only. The seeder does not listen on TCP 53, so an answer too large
# for UDP cannot be fetched again over TCP.
resource "aws_vpc_security_group_ingress_rule" "dnsseed_dns" {
  security_group_id = aws_security_group.dnsseed.id
  description       = "DNS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

# Out: everything. The crawler connects to nodes on whatever port they use.
resource "aws_vpc_security_group_egress_rule" "dnsseed" {
  security_group_id = aws_security_group.dnsseed.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- One seeder per network ----------------------------------------------

resource "aws_instance" "dnsseed" {
  for_each = local.dnsseeds

  ami                    = nonsensitive(data.aws_ssm_parameter.ubuntu_arm64.value)
  instance_type          = "t4g.micro"
  subnet_id              = data.aws_subnet.default[each.value.zone].id
  vpc_security_group_ids = [aws_security_group.dnsseed.id]
  iam_instance_profile   = aws_iam_instance_profile.dnsseed.name

  disable_api_termination = true

  # First boot: frees port 53 from systemd-resolved, installs Docker, writes
  # /opt/dnsseed/docker-compose.yml and starts the container. Docker brings
  # it back after a reboot.
  user_data = templatefile("${path.module}/files/dnsseed-user-data.sh.tftpl", {
    network   = each.key
    image     = local.dnsseed_image
    arguments = each.value.arguments
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
    tags        = merge(local.dnsseed_tags, { Name = "dnsseed-${each.key}", Network = each.key })
  }

  tags = merge(local.dnsseed_tags, { Name = "dnsseed-${each.key}", Network = each.key })

  lifecycle {
    # ami: a newer Ubuntu image must not replace a running seeder as a side
    # effect of an unrelated apply.
    # user_data: read on first boot only. Changing it on a running host
    # stops the host and changes nothing on it. To roll out a change, replace
    # the seeder, in two applies (README, "The seeders"): first set
    # disable_api_termination = false and apply, because AWS refuses to
    # terminate a protected instance and the provider does not lift the
    # protection itself; then terraform apply
    # -replace='aws_instance.dnsseed["testnet"]', and set it back to true.
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "dnsseed" {
  for_each = local.dnsseeds

  domain       = "vpc"
  ipam_pool_id = data.aws_vpc_ipam_pool.owned.id

  tags = merge(local.dnsseed_tags, { Name = "dnsseed-${each.key}" })

  # seed.dash.org and test-seed.dash.org at Cloudflare are these addresses.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip_association" "dnsseed" {
  for_each = local.dnsseeds

  allocation_id = aws_eip.dnsseed[each.key].id
  instance_id   = aws_instance.dnsseed[each.key].id
}

output "dnsseed" {
  description = "The seeders, and the address each seed name at Cloudflare must be."
  value = {
    for network, seeder in aws_instance.dnsseed : network => {
      instance_id = seeder.id
      public_ip   = aws_eip.dnsseed[network].public_ip
    }
  }
}
