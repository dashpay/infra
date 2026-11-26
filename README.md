# dash-infra

Terraform for what Dash Core Group runs in the AWS `dashdev` account
(`854439639386`), tracked in #21.

Networks themselves are not here. The status console creates and operates
testnet and devnet nodes; this repository holds what stays put around them.

## Layout

One directory per stack under `stacks/`. A stack is one Terraform
configuration with its own state, so a change to a website cannot plan a
change to IAM or to a mainnet service, and one stack can be rebuilt without
touching the others.

| Stack | What it holds | State key |
|---|---|---|
| `stacks/account/` | Account-wide things: the state bucket, the GitHub Actions OIDC provider, IAM users, the IPAM and the owned address pools | `dash-infra/account.tfstate` |
| `stacks/dns/` | Public DNS zones and domain registrations | `dash-infra/dns.tfstate` |
| `stacks/services/` | The `dash-services` VPC, `services.dash.org`, the PR Hygiene service (#90) | `dash-infra/services.tfstate` |
| `stacks/apt/` | The signed apt repository for dashmate, `apt.services.dash.org`, and the job that publishes it | `dash-infra/apt.tfstate` |
| `stacks/quorum/` | The quorum list service for testnet and mainnet (`us-east-1`) | `dash-infra/quorum.tfstate` |
| `stacks/console/` | The status console's host, roles, table and bucket, and the VPC it builds devnets in | `dash-infra/console.tfstate` |
| `stacks/web/` | Static sites, `media.dash.org`, the OpenAI proxy behind dashpay.io | `dash-infra/web.tfstate` |
| `stacks/network-services/` | Mainnet Insight and the DNS seeders | `dash-infra/network-services.tfstate` |
| `stacks/storage/` | Host backups and the archive of the old `dashevo` account | `dash-infra/storage.tfstate` |

`modules/` holds what more than one resource block would otherwise repeat.
Each stack has a `README.md` saying what it holds, what it does not, and how
to rebuild it.

All state is in the bucket `dash-terraform-state-854439639386` (`us-east-1`,
versioned), locked with a lock file beside each state object. The bucket
itself is in `stacks/account/`.

The same bucket still holds `quorum-list-server/{base,testnet,mainnet}/`,
the states of the Terraform that used to live in `dashpay/quorum-list-server`.
Everything in them is now in `stacks/quorum/`. They are kept as history and
must not be applied or destroyed from.

## Running a stack

Terraform 1.10 or later, with credentials for `dashdev`. Each lock file
carries hashes for Windows, Linux (x86-64 and ARM64) and macOS on Apple
silicon; add others with `terraform providers lock -platform=…`.

```sh
cd stacks/<stack>
terraform init
terraform plan
```

## Rules every stack follows

- **One file per thing**, named for the thing. `versions.tf` holds the
  `terraform` block and the providers and nothing else.
- **Default tags** on every resource: `ManagedBy = "terraform"`,
  `Source = "dashpay/infra"`, `Stack = "<stack>"`. A resource's own tags say
  what it is (`Name`, and whatever it already carried).
- **Regions.** The provider's region is `us-west-2`. A resource elsewhere
  sets its own `region`. Global services (IAM, Route 53, CloudFront) need
  nothing.
- **Stacks do not read each other's state.** A stack looks up what it needs
  from another by name: a zone with `data "aws_route53_zone"`, the OIDC
  provider with `data "aws_iam_openid_connect_provider"`, the address pool
  with `data "aws_vpc_ipam_pool"`. So a stack can be planned alone, and the
  order for building everything from nothing is simply `account`, `dns`,
  then the rest.
- **Public addresses come from the owned pool** (`68.67.122.0/24`), never
  from Amazon's.
- **No secret is managed here.** Access keys, SecureString parameter
  values, passwords and private keys are not Terraform resources. A stack
  names where a secret lives and its README says how it gets there. State
  still records whatever AWS reports for an adopted resource, so treat the
  state bucket as sensitive: `stacks/quorum/README.md` and
  `stacks/dns/README.md` each name one such case.
- **`prevent_destroy`** on what cannot be made again: zones, buckets with
  data, data volumes, tables, addresses that DNS at another provider points
  at.
- **Adopted resources.** Most of what is here existed before this
  repository and was imported on 2026-11-20. Each stack's `imports.tf` holds
  the `import` blocks that adopted it, and nothing else. They are inert once
  applied. **To build a stack from nothing, delete its `imports.tf`.**
- **A plan with nothing to do is the normal state.** Every stack planned
  "No changes" after its import. If a plan shows a change nobody made in
  this repository, something was changed by hand: find out what before
  applying.
- **`ignore_changes` needs a comment** saying what is being ignored and why.
  It is for facts Terraform cannot reproduce on a host that already runs
  (the image it was launched from), not for hiding drift.

## What Terraform does not manage

- **DNS at Cloudflare.** `dash.org` is a Cloudflare zone. Its records,
  including the NS records that delegate `services.dash.org`,
  `networks.dash.org` and `subscribe.dash.org` to Route 53, are changed by
  hand.
- **Network nodes.** Testnet and devnet hosts belong to the status console
  (`dashpay/status`, `dashpay/dash-network-go`).
- **What runs on a host after first boot.** Terraform makes the host and
  hands it a first-boot script. Deploys are each service's own business.
- **Settings in other repositories**: environments, variables and secrets of
  the repositories that deploy here.

## PR Hygiene service

See [`stacks/services/README.md`](stacks/services/README.md).
