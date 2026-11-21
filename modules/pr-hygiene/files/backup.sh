#!/bin/bash
# Daily backup: a consistent copy of the database, taken with VACUUM INTO
# while the service runs, checked, compressed and sent to S3.
#
# The bucket's lifecycle rule deletes each copy after the retention period.
# That rule, not this script, is what bounds how long a backup can hold data
# a person has since had deleted. Nothing is kept on the host.
set -euo pipefail

. /etc/pr-hygiene/host.env

db=/srv/pr-hygiene/data/pr-hygiene.sqlite3
dir=/srv/pr-hygiene/backup

if [ ! -f "$db" ]; then
  echo "no database yet: nothing to back up"
  exit 0
fi

# As the service's own uid: the database's -wal and -shm files stay
# readable and writable by the service.
as_service() {
  setpriv --reuid "$PRH_SERVICE_UID" --regid "$PRH_SERVICE_UID" --clear-groups "$@"
}

rm -f "$dir"/pr-hygiene-*.sqlite3 "$dir"/pr-hygiene-*.sqlite3.gz
trap 'rm -f "$dir"/pr-hygiene-*.sqlite3 "$dir"/pr-hygiene-*.sqlite3.gz' EXIT

name="pr-hygiene-$(date -u +%Y-%m-%dT%H%MZ).sqlite3"
copy="$dir/$name"

as_service sqlite3 "$db" "VACUUM INTO '$copy'"

check=$(as_service sqlite3 "$copy" 'PRAGMA integrity_check')
if [ "$check" != "ok" ]; then
  echo "the copy failed its integrity check: not uploading" >&2
  exit 1
fi

gzip "$copy"
/snap/bin/aws s3 cp --only-show-errors --region "$PRH_REGION" \
  "$copy.gz" "s3://$PRH_BACKUP_BUCKET/daily/$name.gz"
echo "backed up to s3://$PRH_BACKUP_BUCKET/daily/$name.gz"
