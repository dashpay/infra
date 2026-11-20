# One host: nginx in front of the service's container, SQLite on its own
# volume.
#
# The instance is disposable. Everything that must survive it is on the data
# volume (the database, the TLS certificate, which image is deployed), and
# the address is an Elastic IP. Changing the host's configuration below
# replaces the instance; the new one mounts the volume and starts the same
# image. Expect a few minutes of downtime for that.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_subnet" "this" {
  id = var.subnet_id
}

# Canonical's current Ubuntu 24.04 ARM64 image. Read at creation only (see
# ignore_changes below): a new image must not replace a running host as a
# side effect of an unrelated apply.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  url        = "https://${var.hostname}"

  # The uid the image runs as (distroless "nonroot").
  service_uid = 65532

  tags = {
    Name    = var.name
    Service = var.name
  }
}

# --- Network -----------------------------------------------------------

resource "aws_security_group" "this" {
  name        = var.name
  description = "PR Hygiene service: HTTP and HTTPS in, no SSH"
  vpc_id      = var.vpc_id

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.this.id
  description       = "${each.key} from anywhere: GitHub-hosted runners have no fixed addresses"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# Out: HTTPS (GitHub, AWS, Let's Encrypt, the snap store) and HTTP (Ubuntu's
# package mirrors). No inbound SSH: administration goes through SSM.
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.this.id
  description       = "${each.key} out"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_eip" "this" {
  domain       = "vpc"
  ipam_pool_id = var.ipam_pool_id

  tags = local.tags
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id   = aws_instance.this.id
}

resource "aws_route53_record" "this" {
  zone_id = var.zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.this.public_ip]
}

# --- Storage -----------------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, { Name = "${var.name}-data" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id

  # Detach from a stopped instance, so the file system is never pulled out
  # from under a running database.
  stop_instance_before_detaching = true
}

# --- Host --------------------------------------------------------------

locals {
  host_env = <<-EOT
    PRH_NAME=${var.name}
    PRH_HOSTNAME=${var.hostname}
    PRH_REGION=${local.region}
    PRH_VOLUME_ID=${aws_ebs_volume.data.id}
    PRH_ECR_REPOSITORY=${aws_ecr_repository.this.repository_url}
    PRH_BACKUP_BUCKET=${aws_s3_bucket.backup.bucket}
    PRH_SERVICE_UID=${local.service_uid}
  EOT

  compose = {
    name = var.name
    services = {
      service = {
        # Set by pr-hygiene-deploy: always a digest, never a tag.
        image   = "$${PR_HYGIENE_IMAGE:?}"
        restart = "unless-stopped"
        # Loopback only: nginx is the one way in.
        ports        = ["127.0.0.1:8080:8080"]
        read_only    = true
        cap_drop     = ["ALL"]
        security_opt = ["no-new-privileges:true"]
        tmpfs        = ["/tmp"]
        volumes      = ["/srv/pr-hygiene/data:/data"]
        environment = {
          # Character for character the repository variable
          # PR_HYGIENE_SERVICE_URL: the token's audience.
          PR_HYGIENE_OIDC_AUDIENCE = local.url
        }
        logging = {
          driver  = "json-file"
          options = { "max-size" = "10m", "max-file" = "5" }
        }
      }
    }
  }

  nginx_vars = { hostname = var.hostname }

  unit_tls = <<-EOT
    [Unit]
    Description=Obtain the TLS certificate and turn on HTTPS for the PR Hygiene service
    After=network-online.target nginx.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/sbin/pr-hygiene-tls
    # Let's Encrypt allows five failed validations an hour for a host name.
    Restart=on-failure
    RestartSec=900

    [Install]
    WantedBy=multi-user.target
  EOT

  unit_backup = <<-EOT
    [Unit]
    Description=Back up the PR Hygiene database to S3

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/pr-hygiene-backup
  EOT

  timer_backup = <<-EOT
    [Unit]
    Description=Daily backup of the PR Hygiene database

    [Timer]
    OnCalendar=*-*-* 03:17:00 UTC
    Persistent=true

    [Install]
    WantedBy=timers.target
  EOT

  cloud_config = {
    package_update  = true
    package_upgrade = true
    packages = [
      "amazon-ecr-credential-helper",
      "certbot",
      "docker-compose-v2",
      "docker.io",
      "nginx",
      "sqlite3",
    ]
    write_files = [
      { path = "/etc/pr-hygiene/host.env", permissions = "0644", content = local.host_env },
      { path = "/etc/pr-hygiene/compose.yaml", permissions = "0644", content = yamlencode(local.compose) },
      { path = "/etc/pr-hygiene/nginx-http.conf", permissions = "0644", content = templatefile("${path.module}/files/nginx-http.conf.tftpl", local.nginx_vars) },
      { path = "/etc/pr-hygiene/nginx-tls.conf", permissions = "0644", content = templatefile("${path.module}/files/nginx-tls.conf.tftpl", local.nginx_vars) },
      # Pulls from ECR use the instance role; nothing is stored.
      { path = "/root/.docker/config.json", permissions = "0600", content = jsonencode({ credHelpers = { (split("/", aws_ecr_repository.this.repository_url)[0]) = "ecr-login" } }) },
      { path = "/usr/local/sbin/pr-hygiene-bootstrap", permissions = "0755", content = file("${path.module}/files/bootstrap.sh") },
      { path = "/usr/local/sbin/pr-hygiene-deploy", permissions = "0755", content = file("${path.module}/files/deploy.sh") },
      { path = "/usr/local/sbin/pr-hygiene-tls", permissions = "0755", content = file("${path.module}/files/tls.sh") },
      { path = "/usr/local/sbin/pr-hygiene-backup", permissions = "0755", content = file("${path.module}/files/backup.sh") },
      { path = "/etc/systemd/system/pr-hygiene-tls.service", permissions = "0644", content = local.unit_tls },
      { path = "/etc/systemd/system/pr-hygiene-backup.service", permissions = "0644", content = local.unit_backup },
      { path = "/etc/systemd/system/pr-hygiene-backup.timer", permissions = "0644", content = local.timer_backup },
    ]
    runcmd = [
      ["snap", "install", "aws-cli", "--classic"],
      ["/usr/local/sbin/pr-hygiene-bootstrap"],
    ]
  }

  user_data = "#cloud-config\n${yamlencode(local.cloud_config)}"
}

resource "aws_instance" "this" {
  ami                    = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name

  user_data_base64            = base64gzip(local.user_data)
  user_data_replace_on_change = true

  # IMDSv2 only, and a hop limit of 1 keeps the container from reaching the
  # instance role's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  maintenance_options {
    auto_recovery = "default"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags        = local.tags
  volume_tags = merge(local.tags, { Name = "${var.name}-root" })

  lifecycle {
    ignore_changes = [ami]
  }
}
