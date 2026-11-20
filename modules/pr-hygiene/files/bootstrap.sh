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

# The first 4 MiB read back, completely, as zeros. A volume that has never
# been written does; one with a file system cannot (ext4's superblock is in
# the first 2 KiB). A failed or short read is not "blank".
reads_blank() {
  local n=4194304 got
  # pipefail is on: a read error fails the whole pipeline.
  got=$(head -c "$n" "$dev" | tr -d '\0' | wc -c) || return 1
  [ "$got" = 0 ] || return 1
  [ "$(head -c "$n" "$dev" | wc -c)" = "$n" ]
}

# Formatting is the one step here that can destroy the database, so it needs
# positive proof of a new volume: the low-level probe finds no signature and
# the start of the device reads as zeros. blkid's "nothing found" (exit 2)
# alone is not proof: it also covers "could not read the device". Anything
# short of both is a stop, and the unit retries later.
fstype=$(blkid -p -o value -s TYPE "$dev" 2> /dev/null || true)
if [ -n "$fstype" ]; then
  if [ "$fstype" != ext4 ]; then
    echo "data volume holds $fstype, not ext4: not touching it" >&2
    exit 1
  fi
  echo "data volume has a file system"
elif reads_blank && [ -z "$(lsblk -dno FSTYPE "$dev")" ]; then
  echo "data volume is new (no signature, reads as zeros): formatting"
  mkfs.ext4 -q -L pr-hygiene "$dev"
  udevadm settle
else
  echo "data volume has no recognised file system but is not provably blank: not touching it" >&2
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

# --- Packages ----------------------------------------------------------

# The Elastic IP is attached after launch, and until then the host has no
# way out. Wait for it rather than let a package step fail for good.
retry 120 5 curl -fsS -o /dev/null --max-time 5 http://connectivity-check.ubuntu.com/

export DEBIAN_FRONTEND=noninteractive
# Error-Mode=any: a mirror that cannot be reached is a failure to retry, not
# a warning.
retry 5 20 apt-get update -q -o APT::Update::Error-Mode=any
retry 3 20 apt-get install -y -q \
  amazon-ecr-credential-helper certbot docker-compose-v2 docker.io nginx sqlite3
[ -x /snap/bin/aws ] || retry 3 20 snap install aws-cli --classic

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
