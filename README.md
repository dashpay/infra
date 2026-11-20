# dash-infra

Terraform for Dash Core Group's shared, permanent services in the AWS
`dashdev` account (#21). Networks (testnet, devnets, mainnet support) are not
here: the status console creates and operates those.

One configuration, one environment, one state.

| Path | What |
|---|---|
| `terraform/` | The root configuration: providers, state, and one file per thing |
| `terraform/dns.tf` | The `services.dash.org` zone |
| `terraform/network.tf` | The `dash-services` VPC |
| `terraform/pr-hygiene.tf` | The PR Hygiene service (#90) |
| `modules/github-oidc-role/` | An IAM role for GitHub Actions jobs, pinned to exact subjects |
| `modules/pr-hygiene/` | The PR Hygiene host and everything around it |

## Running it

Terraform 1.10 or later, with credentials for `dashdev` (`854439639386`).

```sh
cd terraform
terraform init
terraform plan
```

State is in `s3://dash-terraform-state-854439639386/dash-infra/terraform.tfstate`,
locked with a lock file beside it.

## What Terraform does not manage

- **The delegation of `services.dash.org`.** `dash.org` is a Cloudflare zone
  holding four NS records for `services.dash.org`. They point at this zone's
  name servers and only change if the zone is recreated.
- **The GitHub Actions OIDC provider** in the account. It predates this
  repository and is shared, so it is looked up.
- **Settings in other repositories**: the `production` environment and the
  variables in `dashpay/stale_prs_are_bad` (below).

## PR Hygiene service

`https://pr-hygiene.services.dash.org`. The code and its operating notes are
in [`dashpay/stale_prs_are_bad`, `service/`](https://github.com/dashpay/stale_prs_are_bad/tree/master/service).

One ARM64 instance runs the service's container behind nginx. SQLite is on
its own volume. The instance has no SSH open; use Session Manager.

### What is where on the host

| Path | What |
|---|---|
| `/srv/pr-hygiene/` | The data volume. Survives the instance |
| `/srv/pr-hygiene/data/` | The database (`/data` in the container) |
| `/srv/pr-hygiene/deploy/image` | The last image that became ready, by digest: what runs, what a rollback returns to, what a new host starts |
| `/srv/pr-hygiene/letsencrypt/` | The TLS certificate (`/etc/letsencrypt` links here) |
| `/etc/pr-hygiene/` | Compose file, nginx configuration, `host.env` |
| `/usr/local/sbin/pr-hygiene-*` | `bootstrap`, `deploy`, `tls`, `backup` |

The host's configuration is delivered at first boot and applied by
`pr-hygiene-bootstrap.service`, which retries until it has succeeded once
(`journalctl -u pr-hygiene-bootstrap`). Changing it in
`modules/pr-hygiene/` replaces the instance: the new one mounts the same
volume, keeps the address and the certificate, and starts the same image.
That costs a few minutes of downtime.

### Deploys

A job in the service's repository builds the image from `master`, pushes it
to the ECR repository here, and runs the SSM document `pr-hygiene-deploy`
with the image's digest. The host pulls that digest, restarts the container,
waits for `/readyz`, and goes back to the previous image if it does not come
up. The job's role can push to that one repository and run that one document;
it has no shell on the host.

The repository needs, once:

- an environment named `production`, restricted to the `master` branch. That
  restriction is what stops other branches from deploying: the role trusts
  `repo:dashpay/stale_prs_are_bad:environment:production`;
- the variable `PR_HYGIENE_DEPLOY_ROLE_ARN` (output `deploy_role_arn`);
- the variable `PR_HYGIENE_SERVICE_URL` (output `url`), to start posting data.

### Backups

`pr-hygiene-backup.timer` runs daily at 03:17 UTC: `VACUUM INTO`, an
integrity check, then `s3://pr-hygiene-backups-854439639386/daily/`. The
bucket deletes each copy after 90 days. A backup still holds what an opt-out
or an account deletion removed from the live database, so that expiry is
part of the service's privacy promise (its README allows 13 months at most).

To restore: stop the container, put the unpacked copy in place as
`/srv/pr-hygiene/data/pr-hygiene.sqlite3` owned by uid 65532, remove any
`-wal` and `-shm` files beside it, and start the container.

### The proxy

`modules/pr-hygiene/files/nginx-*.conf.tftpl` implement the rules in the
service's README ("In front of it"): timeouts, connection and rate limits,
the 1 MB ingest limit, and an access log that holds paths only, with no
query strings and no headers. HTTP/2 is off for now; the file says why.

### Not set up yet

- **Sign-in.** The service runs with sign-in off until the sign-in GitHub
  App exists. It then needs a client secret mounted as a file and three
  environment variables set together.
- **Alerting** on `/readyz` and on stale data.
- **Stage 2** (the worker): a second container with no port, its own volume
  and a GitHub App key.
