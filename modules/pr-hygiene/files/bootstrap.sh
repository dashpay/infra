#!/bin/bash
# Sets up a PR Hygiene host. Run by pr-hygiene-bootstrap.service on a new
# instance until it succeeds once; every step is safe to repeat.
#
# Mounts the data volume, which outlives the instance, and points everything
# that must survive a replacement at it: the database, the TLS certificate,
# and the record of which image is deployed. On a volume that already has
# those, the service comes back as it was.
set -euo pipefail

. /etc/pr-hygiene/host.env

mnt=/srv/pr-hygiene
dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${PRH_VOLUME_ID/-/}"

retry() {
  local tries=$1 pause=$2 n
  shift 2
  for n in $(seq 1 "$tries"); do
    "$@" && return 0
    echo "attempt $n of $tries failed: $*" >&2
    sleep "$pause"
  done
  return 1
}

# --- Packages ----------------------------------------------------------

# First, because the volume step below needs the AWS CLI. Docker and nginx
# start here with nothing to serve; the volume is not in fstab yet, so their
# mount requirement has nothing to wait for.
#
# The Elastic IP is attached after launch, and until then the host has no
# way out. Wait for it rather than let a package step fail for good.
retry 120 5 curl -fsS -o /dev/null --max-time 5 http://connectivity-check.ubuntu.com/

export DEBIAN_FRONTEND=noninteractive
# Finish anything an interrupted earlier run left half-configured. A no-op on
# a clean system.
dpkg --configure -a
# Error-Mode=any: a mirror that cannot be reached is a failure to retry, not
# a warning.
retry 5 20 apt-get update -q -o APT::Update::Error-Mode=any
retry 3 20 apt-get install -y -q \
  amazon-ecr-credential-helper certbot docker-compose-v2 docker.io nginx sqlite3
[ -x /snap/bin/aws ] || retry 3 20 snap install aws-cli --classic

# --- The data volume ---------------------------------------------------

# It is attached after the instance starts.
for _ in $(seq 1 120); do
  [ -b "$dev" ] && break
  sleep 5
done
if [ ! -b "$dev" ]; then
  echo "data volume $PRH_VOLUME_ID did not appear" >&2
  exit 1
fi
udevadm settle

# Formatting is the one step here that can destroy the database, and nothing
# on the device can prove a volume is new: "no signature found" is also what
# a failed probe reports, and an unwritten encrypted volume reads back as
# noise, not zeros. So the proof is kept elsewhere. A volume is formatted
# only if the backup bucket has no record of it; the record is written right
# after, and from then on this script never formats that volume again.
# Failing to read the bucket is a stop, and the unit retries later.
initialised=$(/snap/bin/aws s3api list-objects-v2 --region "$PRH_REGION"   --bucket "$PRH_BACKUP_BUCKET" --prefix "volumes/$PRH_VOLUME_ID"   --query KeyCount --output text)
record() {
  date -u +%Y-%m-%dT%H:%M:%SZ | /snap/bin/aws s3 cp --only-show-errors     --region "$PRH_REGION" - "s3://$PRH_BACKUP_BUCKET/volumes/$PRH_VOLUME_ID"
}

set +e
fstype=$(blkid -p -o value -s TYPE "$dev" 2> /dev/null)
probe=$?
set -e

if [ "$probe" = 0 ] && [ "$fstype" = ext4 ]; then
  echo "data volume has a file system"
  # Formatted, but the record was not written (an interrupted first run).
  [ "$initialised" != 0 ] || record
elif [ "$probe" = 0 ]; then
  echo "data volume holds $fstype, not ext4: not touching it" >&2
  exit 1
elif [ "$initialised" != 0 ]; then
  echo "data volume was initialised before but shows no file system now (blkid exit $probe): not touching it" >&2
  exit 1
elif [ "$probe" = 2 ] && [ -z "$(lsblk -dno FSTYPE "$dev")" ] && [ -z "$(wipefs -n "$dev")" ]; then
  echo "data volume has never been initialised and holds no signature: formatting"
  mkfs.ext4 -q -L pr-hygiene "$dev"
  udevadm settle
  record
else
  echo "could not probe the data volume (blkid exit $probe): not touching it" >&2
  exit 1
fi

# nofail keeps the host bootable (and reachable through SSM) if the volume is
# ever missing. Everything that uses the volume has RequiresMountsFor on it
# instead (see the units and drop-ins), so nothing starts on an empty
# directory.
mkdir -p "$mnt"
if ! grep -q "[[:space:]]$mnt[[:space:]]" /etc/fstab; then
  uuid=$(blkid -o value -s UUID "$dev")
  echo "UUID=$uuid $mnt ext4 defaults,nofail,x-systemd.device-timeout=60 0 2" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "$mnt" || mount "$mnt"

install -d -o "$PRH_SERVICE_UID" -g "$PRH_SERVICE_UID" -m 0700 "$mnt/data" "$mnt/backup"
install -d -m 0700 "$mnt/deploy" "$mnt/letsencrypt"

# --- TLS and nginx -----------------------------------------------------

# The certificate lives on the volume, so a new instance does not ask Let's
# Encrypt for another one.
if [ ! -L /etc/letsencrypt ]; then
  if [ -d /etc/letsencrypt ]; then
    cp -an /etc/letsencrypt/. "$mnt/letsencrypt/"
    rm -rf /etc/letsencrypt
  fi
  ln -s "$mnt/letsencrypt" /etc/letsencrypt
fi

install -d -m 0755 /var/www/acme
rm -f /etc/nginx/sites-enabled/default
install -m 0644 /etc/pr-hygiene/nginx-http.conf /etc/nginx/conf.d/pr-hygiene-http.conf
nginx -t
systemctl reload-or-restart nginx

systemctl enable --now pr-hygiene-backup.timer
systemctl enable pr-hygiene-tls.service
systemctl start --no-block pr-hygiene-tls.service

# --- The service -------------------------------------------------------

# A replacement host starts the last image that became ready: deploy/image
# is written only then. A new service has none until its first deploy. The
# deploy lock is held so a deploy arriving now waits its turn out.
exec 9> /run/pr-hygiene-deploy.lock
flock 9
if [ -s "$mnt/deploy/image" ]; then
  export HOME=/root DOCKER_CONFIG=/root/.docker
  printf 'PR_HYGIENE_IMAGE=%s\n' "$(cat "$mnt/deploy/image")" > /run/pr-hygiene-image.env
  docker compose --env-file /run/pr-hygiene-image.env -f /etc/pr-hygiene/compose.yaml \
    up -d --quiet-pull
fi
flock -u 9

install -d -m 0755 /var/lib/pr-hygiene
touch /var/lib/pr-hygiene/bootstrapped
echo "bootstrap complete"
