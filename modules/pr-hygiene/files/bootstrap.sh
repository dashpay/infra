#!/bin/bash
# First boot of a PR Hygiene host (run once, by cloud-init).
#
# Mounts the data volume, which outlives the instance, and points everything
# that must survive a replacement at it: the database, the TLS certificate,
# and the record of which image is deployed. On a volume that already has
# those, the service comes back as it was.
set -euo pipefail

. /etc/pr-hygiene/host.env

mnt=/srv/pr-hygiene
dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${PRH_VOLUME_ID/-/}"

# The volume is attached after the instance starts.
for _ in $(seq 1 120); do
  [ -b "$dev" ] && break
  sleep 5
done
if [ ! -b "$dev" ]; then
  echo "data volume $PRH_VOLUME_ID did not appear" >&2
  exit 1
fi
udevadm settle

# Format only a volume that provably has no file system: blkid's low-level
# probe exits 2 for "nothing found" and anything else non-zero for "could
# not tell", which must never lead to a format.
set +e
fstype=$(blkid -p -o value -s TYPE "$dev")
probe=$?
set -e
case "$probe" in
  0) echo "data volume has a file system: $fstype" ;;
  2) echo "data volume is blank: formatting"; mkfs.ext4 -q -L pr-hygiene "$dev" ;;
  *) echo "could not probe $dev (blkid exit $probe): not touching it" >&2; exit 1 ;;
esac

mkdir -p "$mnt"
if ! grep -q "[[:space:]]$mnt[[:space:]]" /etc/fstab; then
  uuid=$(blkid -o value -s UUID "$dev")
  echo "UUID=$uuid $mnt ext4 defaults,nofail,x-systemd.device-timeout=60 0 2" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "$mnt" || mount "$mnt"

install -d -o "$PRH_SERVICE_UID" -g "$PRH_SERVICE_UID" -m 0700 "$mnt/data" "$mnt/backup"
install -d -m 0700 "$mnt/deploy" "$mnt/letsencrypt"

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
systemctl reload nginx

systemctl enable --now pr-hygiene-backup.timer
systemctl enable pr-hygiene-tls.service
systemctl start --no-block pr-hygiene-tls.service

# A replacement host starts the image the last one ran. A new service has
# none until its first deploy.
if [ -s "$mnt/deploy/image.env" ]; then
  export HOME=/root DOCKER_CONFIG=/root/.docker
  docker compose --env-file "$mnt/deploy/image.env" -f /etc/pr-hygiene/compose.yaml up -d
fi
