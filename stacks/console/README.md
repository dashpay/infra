# console

The footing of the Dash status console, `https://status.testnet.networks.dash.org`
(`dashpay/status`, with the engine `dashnet` from `dashpay/dash-network-go`).
The console monitors testnet, mainnet and the devnets and is the only thing
that upgrades, resets, creates and destroys networks. All of this was made by
hand between February and October 2026 and is adopted here as it runs.

## What is here

| File | What |
|---|---|
| `host.tf` | The status host `status-dashboard` (`i-0089435363e96c711`, `t4g.medium`, `us-west-2c`, Ubuntu 24.04), its one 20 GB disk, the Elastic IP `68.67.122.250` and the security group `status-dashboard` (80 and 443) |
| `host-role.tf` | The host's role `dash-status-server`, its instance profile and its two policies: `status-agent` (everything the console may do in AWS) and `status-inventory` (what the `/aws` page reads) |
| `operations-roles.tf` | `dash-status-testnet-operations` and `dash-status-devnet-moutai-operations`, assumed by a GitHub Actions workflow of `dashpay/dash-network-go` |
| `operations-bucket.tf` | `dash-status-operations-854439639386-usw2`: versioned, AES256, private, TLS only, no expiry |
| `state-table.tf` | The DynamoDB table `dashnet-managed-state`, the engine's record of every network |
| `devnets.tf` | What devnets are built into: the VPC `dashnet-devnets` (`10.42.0.0/16`), its subnet, internet gateway and route table, the security group `dashnet-devnet-nodes` with its nine rules, and the key pair `dash-status-agent` |
| `dns.tf` | The record `status.testnet.networks.dash.org` |
| `lookups.tf` | What is used and not owned (below) |
| `tags.tf` | One tag kept as found |

## What is not here

- **Everything the console creates.** Each devnet's instances, their disks,
  their Elastic IPs and their names under `<devnet>.networks.dash.org` are
  made and removed by the console and carry `dashnet:managed-by =
  dash-network-go`. On 2026-11-20 that was Palmatum and Drill, 14 instances
  each. Terraform and the console never own the same resource: Terraform has
  the network they sit in (tag `dashnet:purpose`), the console has what is
  in it. `devnets.tf` says where the line runs and why nothing here can
  reach across it.
- **Testnet's hosts.** The console operates them (kind "enrolled") and does
  not create them. They come from `dash-network-deploy`, which is retired.
- **The VPC `dn-testnet`, its subnet `testnet-public2` and the security
  group `testnet-ssh`**, which the status host uses. They belong to the
  retired testnet tooling and to all of testnet's nodes. Looked up by name.
  `testnet-ssh` is what opens the host's port 22, to the whole internet.
- **The key pair `dn-testnet-auth`** the host was launched with. Named, not
  adopted. Who holds its private half was not established.
- **The zone `networks.dash.org`**: the `dns` stack.
- **The address pool and the GitHub Actions identity provider**: the
  `account` stack.
- **The main route table, default security group and default network ACL**
  of `dashnet-devnets`. AWS makes them with the VPC. Nothing uses them.
- **What runs on the host**: the containers, nginx, the certificate,
  Tailscale. Set up by hand; deploys are `deploy/deploy.sh` in
  `dashpay/status`, run on the host.
- **`status.dash.org`**, which redirects to the console. `dash.org` is a
  Cloudflare zone.
- **The variables and environments of `dashpay/dash-network-go`** that name
  the operations roles and the bucket.

## Rebuild from nothing

Needs the `account` stack (address pool, identity provider) and the `dns`
stack (zone). The host also needs the testnet VPC to exist. If that is gone
too, change all three lookups in `lookups.tf` before the apply: `aws_vpc.testnet`
to the replacement VPC, `aws_subnet.testnet_public2` to a public subnet in it,
and `aws_security_group.testnet_ssh` to a group in that VPC that opens port 22
(create one by hand if there is none; it is the only thing that opens the
host's SSH port).

Delete `imports.tf`, then `terraform apply`.

### What Terraform recreates

| Thing | What comes back | What does not |
|---|---|---|
| Status host | A bare Ubuntu 24.04 instance with the role, the security groups and an address | Everything on its disk. There is no first-boot script |
| Elastic IP | An address from the owned pool | `68.67.122.250` itself, if the allocation was released: the pool hands out whichever address is free. The DNS record and the devnet SSH rule follow it by themselves |
| Roles and policies | All of it, exactly | Nothing. The role ARNs are the same again |
| Operations bucket | The empty bucket | Its 12 objects from 2026-09-28. Nothing reads them |
| `dashnet-managed-state` | The empty table | Every item (below) |
| Devnet VPC, subnet, security group | The same shape with **new ids** | The ids the console has in its settings: put the output `devnet_scaffolding` into Settings, new devnet defaults |
| Key pair `dash-status-agent` | The public key written in `devnets.tf` | It is only useful while the agent still has the matching private key |
| DNS record | Yes | |

### What exists only on the status host

Nothing on the host is backed up. There is no snapshot of its disk, no
image, no AWS Backup plan, no job on the host that copies anything away,
and the host's role cannot write to S3 (checked 2026-11-20). The disk is
deleted with the instance. Termination protection is off.

| Path | What | If it is lost |
|---|---|---|
| `/srv/dash-status/agent/id_ed25519` | The agent's SSH key. Every enrolled testnet node and every devnet node trusts it | A new agent makes itself a new key. **Testnet** should heal by itself: the agent pushes its key through EC2 Instance Connect to a host that refuses it, and its role allows that for `DashNetwork=testnet` (read from the code, not tried). **Running devnets do not**: the role does not allow it for devnet tags, so the agent is locked out of them until someone adds its new key on each node another way. For new devnets, replace the key pair: put the new public key into `devnets.tf`, remove `public_key` from its `ignore_changes` for that one apply (otherwise Terraform ignores the new key and the old one stays), check that the plan replaces `aws_key_pair.status_agent`, apply, then put the `ignore_changes` entry back. Until then new devnets are launched with the old key |
| `/srv/dash-status/agent/devnets/<name>/` (640 MB) | Each console devnet's plans, lock files, stage records, secrets and the exact `dashnet` binary its plans were made with | The console has nothing left to operate that devnet with: no upgrade, reset or delete. Its instances and addresses have to be found by tag (`dashnet:network`) and removed by hand |
| `/srv/dash-status/agent/hostkeys.json` | The SSH host key pinned for each instance | Pinned again on first contact, without the earlier check |
| `/srv/dash-status/data/settings.json` | Who may sign in and with which role, network definitions, thresholds, devnet defaults | The console starts with the defaults in `shared/settings.js`: one admin (`ktechmidas`), testnet, the devnet ids above. Access for everyone else is set again by hand |
| `/srv/dash-status/data/api-tokens.json` | Hashes of the bots' API tokens | Every token stops working. Issue new ones |
| `/srv/dash-status/data/` the rest (71 MB) | Operation history and logs, devnet registry, CI and website history, incident state, sessions | History is gone. Everyone signs in again |
| `/etc/dash-status/oauth.env` | The GitHub OAuth app's client id and secret | Sign-in does not work until they are put back. The infraclaw secret store has entries of that name (`STATUS_GITHUB_OAUTH_CLIENT_ID`, `_SECRET`; not compared with the host). Otherwise make a new secret in the OAuth app |
| `/etc/dash-status/mainnet.env` | The token the mainnet observer reports with | The observer host holds the same value (`/etc/dash-mainnet-observer/env` on `ubuntu-server-2`). Copy it back or set a new one in both places |
| `/etc/dash-status/incidents/` | HMAC key, read token and receiver address for incident delivery | Shared with the incident broker on `ubuntu-server-2`. Set again in both places |
| `/etc/dash-status/compose.yml`, `runtime.env`, `config/` | The original single-network collector that still serves the legacy API on port 3002 (`/api/nodes`, `/api/events`, …), with its own inventory file and its own SSH key | The legacy API is down until it is set up again. The mode is in `dashpay/status` (`deploy/API-COMPATIBILITY.md`); the image that runs now is a local build with no tag |
| `/etc/nginx/sites-available/status-dashboard` | The site: proxy to `127.0.0.1:3006`, the legacy snippet, the certificate | Written again by hand. Only the snippet is in `dashpay/status` (`deploy/nginx-legacy-api.conf`). Certbot issues a new certificate once the name points at the host |
| `/opt/dash-status/` | The checkout that `deploy.sh` builds from (it has local changes), `patches/` with the compose file the key helper runs from and the website probe | Cloned again. The website probe is `monitoring/websites/` in the repository |
| `/root/<task>-<date>/` (1.1 GB, about 90 folders) | Rollback manifests of past deploys | Not needed for a rebuild. They only name images on this host |
| Docker images (118, 8 GB) | Every build since September | Built again from the repository |
| Tailscale identity `dash-status` | The host's place in the tailnet | Joined again by whoever administers the tailnet |
| `ubuntu`'s `authorized_keys` | Six keys added by hand | A new host has only the key of `dn-testnet-auth` |

### What is in the table

One item per network, keyed `<account>/<region>/<network>`. **Point-in-time
recovery is off, there is no on-demand backup and deletion protection is
off** (checked 2026-11-20), so a deleted item or table is gone.

- **Testnet** is enrolled, not created: its record can be made again from
  the running hosts with the console's Enroll (`dashnet managed-import`,
  `enroll`), without restarting anything.
- **A console devnet** is recorded as it was built. Without its item the
  engine no longer knows the devnet, so expect that the console can neither
  operate nor delete it (not tried). The devnet keeps running; removing it
  is manual.
- The records of destroyed devnets are history only.

### Putting the console back on a new host

There is no script for this and it has not been tried. From `deploy/` in
`dashpay/status` and from what is on the host today:

1. Get in. The new host has only the `dn-testnet-auth` key. If nobody has
   it, push a key with EC2 Instance Connect as an IAM user (port 22 is open
   through `testnet-ssh`).
2. Install `docker.io`, `docker-compose-v2`, `nginx`, `certbot`,
   `python3-certbot-nginx`, `git`. Tailscale if the host is to be on the
   tailnet again.
3. `git clone https://github.com/dashpay/status /opt/dash-status/src`.
4. Create `/etc/dash-status/oauth.env` (`GITHUB_OAUTH_CLIENT_ID`,
   `GITHUB_OAUTH_CLIENT_SECRET`) and `/etc/dash-status/mainnet.env`
   (`MAINNET_REPORT_TOKEN`), mode 600. The compose file needs both to exist.
   The OAuth app's callback is the public name, so it does not change.
5. If a copy of `/srv/dash-status/data` and `/srv/dash-status/agent` exists,
   put it back now, owned by uid 1000. Today no copy exists.
6. For devnet key export, create `/srv/dash-status/key-access` (uid 1000,
   mode 700). For incident delivery, restore `/etc/dash-status/incidents/`.
7. `sudo /opt/dash-status/src/deploy/deploy.sh`. It builds the image on the
   host (Go and Node stages) and starts `web` and `agent`. Web listens on
   `127.0.0.1:3006`.
8. nginx: a site that proxies `/` and `/api/` to `127.0.0.1:3006` and
   includes `deploy/nginx-legacy-api.conf`; then
   `certbot --nginx -d status.testnet.networks.dash.org`.
9. Website probes: install the two units from `monitoring/websites/`.
10. Sign in as `ktechmidas`, set access and settings again, check that the
    devnet ids in Settings match the output `devnet_scaffolding`.
11. Check with `scripts/check-console-features.mjs` and
    `scripts/check-legacy-api.mjs` from the repository.

With the disk lost and nothing restored, the result is a console that sees
and operates testnet again once the agent's new key has reached the nodes,
has no history, and cannot manage the devnets that were running.

## What an operator must know

- **The host is the single point of failure for operating every network,
  and nothing on it is backed up.** A scheduled snapshot of the one volume
  (`vol-0562e215ba84b9acf`) would cover all of the table above. It is not
  set up. Until it is, a manual snapshot before risky work on the host is
  the only restore point.
- **The disk is 85 % full** (16 of 19 GB on 2026-11-20). A full disk fails
  the next image build. `volume_size` in `host.tf` can be raised without
  stopping the host; the file system then has to be grown on the host.
- **Nothing here may replace the host.** `prevent_destroy` is set. A change
  to `subnet_id`, `key_name` or the disk's `encrypted` would need a
  replacement; `instance_type` needs a stop.
- **The security group ids, the subnet id and the key pair's name are in
  three places**: here, in the host role's policy (which follows this stack
  by reference) and in the console's settings (which does not).
- **Policies of `dash-status-server` are changed here.** `dashpay/status`
  describes what the agent needs (`README.md`, `deploy/iam/`); this stack is
  what grants it.
- **The route table of the devnet subnet is managed whole.** A route added
  by hand disappears on the next apply. Security group rules are separate
  resources: one added by hand stays, unmanaged.
- **The operations roles and the bucket have not been used since
  2026-09-28.** The console runs operations from the host now. The Moutai
  role is a leftover of a devnet destroyed on 2026-10-01.
