# What every host in this stack is launched with.

locals {
  # The account's old shared key pair. It is not managed anywhere: the
  # private key is with whoever holds it.
  key_name = "dashdev.rsa"

  # The release a new quorum server downloads at first boot. The running
  # hosts are on 0.7.0, a CI build that was never published as a release and
  # was copied onto them by hand, so this is the nearest thing a new host
  # can fetch. It has not been run here.
  quorum_server_version = "v0.8.0"
}

# Canonical's current Ubuntu 22.04 image, for a host that is built new. The
# running hosts ignore it (ignore_changes on ami): they stay on the image
# they were launched from.
data "aws_ami" "ubuntu" {
  region      = local.region
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
