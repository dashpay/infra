# The bastion: the way in to the hosts in the private subnets. They accept
# SSH from this security group only.
#
#   ssh -J ubuntu@<bastion> ubuntu@<private address>     (key pair dashdev.rsa)
#
# Its public address is an Amazon one assigned at launch, not an Elastic IP:
# it changes if the instance is stopped and started. Read it from the output
# "bastion_public_ip".

# As found: SSH from anywhere.
resource "aws_security_group" "bastion" {
  region      = local.region
  name        = "testnet-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.shared_tags, { Name = "testnet-bastion-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  region            = local.region
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "bastion" {
  region            = local.region
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Nothing is installed on it: a plain Ubuntu with the key pair.
resource "aws_instance" "bastion" {
  region                 = local.region
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = local.key_name
  subnet_id              = aws_subnet.public["1"].id
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # As found: the instance metadata service still answers version 1
  # requests.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  tags = merge(local.shared_tags, { Name = "testnet-bastion" })

  lifecycle {
    # ami: the running host was launched from the Ubuntu 22.04 image of June
    # 2025. A newer image must not replace it.
    ignore_changes = [ami]
  }
}
