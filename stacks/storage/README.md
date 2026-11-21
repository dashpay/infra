# storage

Data that exists once and cannot be made again: the host backups and the
archive of the old `dashevo` account. Both buckets were created by script on
2026-11-20 (#19) and adopted here as they are.

## What is here

| File | What |
|---|---|
| `backups.tf` | Bucket `dash-backups-854439639386-usw2`, and the IAM users `backup-wp2021` and `backup-forum2023` with their policies |
| `archive.tf` | Bucket `dash-dashevo-archive-854439639386-usw2` and its bucket policy |
| `private-buckets.tf` | What both buckets share: public access blocked, ACLs off, encryption |
| `snapshot.tf` | Snapshot `snap-04da04a6a2a0c072d`, kept on purpose |

### Host backups

`wp2021` (the WordPress behind dash.org) and `forum2023` (the forum) are
hosts outside AWS. Cron scripts in `/root/` on each upload database dumps
and copies of the site's files to `cowboy/<host>/` in the bucket: on
`wp2021`, `backup-wp-db.sh` and `backup-wp-site.sh`; on `forum2023`,
`backup-forum-db.sh`, `backup-forum-site.sh`, `forum-backup-db.sh` and
`forum-backup-site.sh`.

Each host has its own IAM user. It can list the bucket and read and write
under its own prefix. It cannot delete anything. It can overwrite, which is
why the bucket is versioned: the overwritten object stays as an older
version.

Objects move to Glacier Instant Retrieval 30 days after they are written
(objects under 128 KB stay where they are). They can still be read at once;
reading is charged per GB. Nothing is ever deleted by a rule, so the bucket
only grows.

The bucket also holds the complete history of the old account's
`dashevo-backups` bucket: 1.67 million object versions, about 4.2 TB, under
`cowboy/<host>/` for some thirty past and present hosts and under `db/`,
`email/`, `github/`, `other/` and `site/`. It was copied on 2026-11-20 and
checked against the source version by version.

**Treat the whole bucket as secret.** The backups include each host's
`/root`, with its `.ssh` and `.aws` directories.

### The archive

`<old bucket name>/<key>` for eight buckets of the old account:
`dashevo-infra`, three Terraform state buckets, old copies of static sites,
and a 2025 WordPress dump. Seven of them have since been deleted;
`dashevo-infra` still exists. Current versions only, stored as Glacier
Instant Retrieval, checked against the sources on 2026-11-20. Old Terraform
state can contain secrets, so this bucket is secret too.

Nothing writes to it any more. Its bucket policy still lets the old
account's user `daniel` write, which is how it was filled.

### The snapshot

A copy of an unattached, untagged 50 GB volume from the old account that
nobody could identify. Contents unknown. It is managed here so that it has
an owner and is not cleaned up as an orphan.

## What is not here

- **Access keys.** No secret is in the state. Each backup user's key is made
  by hand and exists only in `/root/.aws/credentials` on its host:

  ```sh
  aws iam create-access-key --user-name backup-wp2021
  ```

- **The hosts and their backup scripts.** `wp2021` and `forum2023` are not
  in AWS and not in this repository.
- **A leftover bucket policy on the backups bucket.** It has two statements
  that let a role of the old account replicate into the bucket. That role
  was deleted when the copy was finished, so the policy now names a role
  that does not exist and allows nothing. It is not adopted, because a
  policy naming a deleted role cannot be applied again. Remove it by hand:

  ```sh
  aws s3api delete-bucket-policy --bucket dash-backups-854439639386-usw2
  ```

- **Other buckets** (`pr-hygiene-backups-…` is in `services`; the static
  sites and media buckets are in `web`; the state bucket is in `account`).

## Rebuild from nothing

**Neither bucket's contents can be recreated.** That is why both have
`prevent_destroy` and the backups bucket is versioned.

**Nothing copies either bucket anywhere else.** There is no replication
rule, no AWS Backup plan and no second copy in another region or account.
The source of the backup history, `dashevo-backups` in the old account, is
being emptied by an expiry rule set on 2026-11-20; of the archive's sources
only `dashevo-infra` still exists. If one of these buckets is lost, what was
in it is gone.

What Terraform does recreate, after deleting `imports.tf` and leaving out
`snapshot.tf`: two empty buckets with the same settings, and the two users
with their policies. A bucket name can be used again only once the old
bucket is completely gone. Then, by hand:

1. Make an access key for each backup user and put it in
   `/root/.aws/credentials` on its host.
2. Run each host's backup scripts once and check that objects arrive under
   `cowboy/<host>/`.

From then on the hosts fill the backups bucket again with new backups, as
long as the hosts themselves still exist. The history is not restored. The
archive stays empty: its sources no longer exist. The snapshot cannot be
made again.

## What an operator must know

- **The archive bucket is not versioned**, and the old account's `daniel`
  may still write to it. An object overwritten there is lost. Turn
  versioning on, or remove the bucket policy once nothing needs to be copied
  from `dashevo-infra` again.
- Versioning protects the backups against overwriting, not against someone
  with administrator rights in this account deleting versions. There is no
  MFA delete and no Object Lock.
- Glacier Instant Retrieval bills at least 90 days for every object. That
  suits backups that are kept for good; it makes this bucket the wrong place
  for anything short-lived.
- To add a host: add its name to `backup_hosts` in `backups.tf`, apply, make
  its access key by hand.
