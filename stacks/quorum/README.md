# quorum

The Dash quorum list service for testnet and mainnet, in `us-east-1`:
`https://quorums.testnet.networks.dash.org` and
`https://quorums.mainnet.networks.dash.org`. The code is
[`dashpay/quorum-list-server`](https://github.com/dashpay/quorum-list-server).
Mainnet clients depend on the mainnet one.

Everything here existed before this repository and was adopted on
2026-11-20 as it was found, including what looks wrong. This stack replaces
the three Terraform states of `dashpay/quorum-list-server`
(`quorum-list-server/base`, `/testnet`, `/mainnet` in the state bucket, last
applied 2025-07-01). Those states and the `terraform/` directory of that
repository must not be applied again.

## What is here

```
quorums.<network>.networks.dash.org      A, AAAA, HTTPS records
  -> CloudFront distribution             CloudFormation stack quorums-cdn-<network>
  -> testnet-alb, HTTPS listener         rule by Host header: 150 testnet, 200 mainnet
  -> quorum server, port 3000            t3.micro
  -> Dash Core RPC                       t3.medium, data directory on EFS
```

Shared by both networks (files in this directory):

| File | What |
|---|---|
| `network.tf` | VPC `testnet-vpc` (`10.0.0.0/16`), two public and two private subnets, internet gateway, one NAT gateway, route tables |
| `load-balancer.tf` | `testnet-alb`, its security group and its one listener (443) |
| `certificates.tf` | Two ACM certificates for the same names, and their four validation records |
| `bastion.tf` | `testnet-bastion`, the way in to the private hosts |
| `hosts.tf` | The image, key pair and server release a new host gets |
| `dns.tf` | Lookup of the zone `networks.dash.org` |

Per network, `testnet.tf` and `mainnet.tf` each use
`modules/quorum-network` once: Core backend, quorum server, their security
groups, the EFS file system with two mount targets, target group, listener
rule, CloudFormation stack, DNS records. Testnet also has a replica of its
file system in `us-west-2`.

`mainnet-recovery-host.tf` is the one thing outside that shape:
`mainnet-quorum-server-recovery-20261005` (`i-03b4a78195dd8b42e`), built by
hand on 2026-10-05. **It is the only instance in `mainnet-quorum-tg` and
serves mainnet.** The module's own `mainnet-quorum-server`
(`i-094434fbc0847aac7`) still runs and is registered nowhere; it is kept as
the way back.

Names say "testnet" on things mainnet uses too (the VPC, the load balancer,
the bastion). They are kept as they are in AWS.

## What is not here, and who has it

- **The zone `networks.dash.org`**: the `dns` stack.
- **The key pair `dashdev.rsa`**: not managed anywhere. Whoever holds the
  private key can reach the private hosts through the bastion.
- **What runs on the hosts after first boot**: Core and server upgrades,
  `dash.conf`, `config.toml`. All done by hand over SSH so far.
- **The RPC password** shared by a Core backend and its quorum server. It is
  in `dash.conf` on the file system and in `config.toml` on the quorum
  server, nowhere else that Terraform manages.
- **What CloudFormation makes inside the two stacks**: the distribution, a
  cache policy, an origin request policy and a Route 53 health check that
  requests `/quorums` every 30 seconds. Terraform holds the stack, not these.
- **The replica file system** in `us-west-2` (`fs-0b16425667dc840cb`). EFS
  makes and owns it; Terraform holds only the replication.
- **Recovery leftovers of 2026-10-05**: image
  `mainnet-quorum-access-recovery-20261005` (`ami-01e626ed8a026c719`, the
  recovery host's image) and the snapshots `snap-0c2bc1abd051e785a` and
  `snap-0dc2579522fac5f44` of the mainnet Core backend's system disk. Kept
  until latte says otherwise.
- **Monitoring**: nothing in AWS (no alarms in `us-east-1`). The status
  console checks testnet's `/health`; the mainnet observer on
  `ubuntu-server-2` checks mainnet's `/quorums` and `/masternodes`.

### In this VPC but not in this stack

These share the VPC and, for the faucet, the load balancer. Nothing here
manages them, and nothing here may remove them: listener rules, target
groups and security group rules are separate resources, so a plan of this
stack does not see them.

| What | Detail |
|---|---|
| Testnet faucet | Instance `testnet-faucet` (`i-0ac97b31ba86231c4`) with security group `launch-wizard-3` |
| Faucet on `testnet-alb` | Target groups `faucet-tg`, `faucet-anubis-tg`, `faucet-cap-tg`; listener rules at priorities 90, 91, 92, 100 for `faucet.testnet.networks.dash.org`; the record `faucet.testnet.networks.dash.org` (CNAME to the load balancer) |
| `base-sdk-server` | Instance `i-0dc34250af328f1f2` with security group `launch-wizard-1`; load balancer `base-sdk-server-alb` with its two listeners and target group `base-sdk-server-tg`. That load balancer uses the VPC's default security group, which is open on 80 and 443 |
| VPC defaults | The main route table (no subnets use it), the default network ACL, the default security group |

The faucet depends on this stack without being in it: its rules sit on this
listener, its name is on both certificates (and its validation record is
kept here for that reason), and its DNS record points at this load
balancer's name.

## Rebuild from nothing

The `account` and `dns` stacks come first: the zone must exist and be
delegated.

1. Delete `imports.tf`.
2. In `mainnet.tf` remove `serving_instance_id`, and delete
   `mainnet-recovery-host.tf`. The recovery host is a copy of a host that
   would no longer exist; a new mainnet service is served by the module's
   own quorum server.
3. Make sure a key pair named `dashdev.rsa` exists in `us-east-1`, or change
   `key_name` in `hosts.tf`.
4. `terraform apply`. It can stop at the listener or at the CloudFormation
   stacks because the certificates are not issued yet (there is no resource
   that waits for them). Wait until both show as issued, a few minutes, and
   apply again.
5. Finish each network by hand, below.

**What Terraform recreates:** the network, the load balancer and listener,
both certificates and their validation records, the bastion, and per network
an empty file system, a Core backend, a quorum server, the target group, the
rule, the distribution and the DNS records.

**What first boot does.** The scripts are
`modules/quorum-network/files/*.tftpl`. No host has been built from them in
their present form; the running hosts were launched in July 2025 from
earlier versions that had the RPC password written in them.

- Core backend: installs the Core release named by `core_version`, mounts
  the file system at `/mnt/efs`, links `/home/dash/.dashcore` to
  `/mnt/efs/dashcore`, writes `dash.conf` with a new random RPC password
  **only if the file system has none**, and starts `dashd`. On an empty
  file system Core then syncs the whole chain from the network.
- Quorum server: installs the release named in `hosts.tf`, writes
  `config.toml` without the password, enables the service and does not
  start it.

**What has to be done by hand:**

- Copy `rpcpassword` from `/mnt/efs/dashcore/dash.conf` on the Core backend
  into `/home/quorum/quorum-list-server/config.toml` on the quorum server,
  then `systemctl start quorum-list-server`. Check `/health` **and**
  `/quorums` on port 3000: `/health` answers even when the server has no
  quorums to give.
- Testnet only: add the `/proofs` cache behaviour to the CloudFront
  distribution (all methods, caching disabled). It was added by hand to the
  live distribution and is not in the template.
- The faucet's target groups, rules and DNS record, if the load balancer is
  new. They are not this stack's.

**What is on the file systems.** Core's data directory and nothing else:
blocks, chain state, the masternode and quorum databases, `dash.conf`. No
wallet and no masternode key (checked for mainnet on 2026-10-05, not
checked for testnet). On 2026-11-20 testnet's held 6.5 GB and mainnet's
60 GB. All of it comes back by syncing from the network. How long that
takes has not been measured here: plan for hours on testnet and a day or
more on mainnet, on a `t3.medium` writing to EFS.

- Testnet's file system is replicated to `us-west-2` by EFS. To use the
  replica, the replication has to be deleted first, which makes the copy
  writable; it is in another region, so the data then has to be copied or
  replicated back. Never done here.
- **Mainnet's file system has no replica and no backup.** The mainnet Core
  backend's system disk holds a cold copy of the data as it was before the
  upgrade to 23.1.8 (`/var/backups/infraclaw/mainnet-core-pre-23.1.8-20261005`,
  also in `snap-0dc2579522fac5f44`). That is a rollback input for that
  upgrade, not a backup of today's data.

**What the quorum servers keep.** The binary, `config.toml` (with the RPC
password) and a log, all under `/home/quorum/quorum-list-server/`. No
database: what they serve is read from Core and held in memory, so a new
server is complete once it has the password.

**What would be lost:** the chain data until it has synced again; the RPC
passwords (new ones are made); the log files; the versions installed by
hand (new hosts install what `core_version` and `hosts.tf` say); the
`/proofs` behaviour on testnet; the distributions' and the load balancer's
DNS names; the NAT gateway's and the bastion's public addresses.

### Rebuilding one host

The hosts, file systems, load balancer and CloudFormation stacks carry
`prevent_destroy`. To replace a host, take that line out for the one
change, replace the instance, finish it by hand as above, and put the line
back.

A Core backend that is replaced while its file system survives mounts it
again, keeps `dash.conf` and its password, and comes back on the same
private address, so its quorum server needs no change. `core_version` must
not be older than the version that last wrote the data: mainnet's was
migrated by 23.1.8 and cannot be opened by 22.

## What an operator must know

- **Passwords in user data.** The four hosts launched in July 2025 (both
  Core backends, both original quorum servers) have their first-boot script,
  with the RPC password of that day in it, as instance user data. Anyone who
  may call `DescribeInstanceAttribute` can read it, and since provider
  version 6 Terraform keeps user data readable in the state. Whether the
  hosts still use these passwords was not checked. Core's RPC port is
  reachable only from inside the VPC. Rotating the passwords on the hosts
  makes the copies harmless; the first-boot scripts here carry none.
- **Switching the mainnet target.** Do it by hand, then make `mainnet.tf`
  say the same: register the new instance on port 3000 in
  `mainnet-quorum-tg`, wait until it is healthy and `/quorums` is right,
  then deregister the old one (300 seconds of draining). The way back to
  the original is the same in reverse.
- **Getting in.** Private hosts: through the bastion with `dashdev.rsa`.
  Recovery host: directly, as `ubuntu`, with latte's ed25519 key, and only
  from `153.67.85.166`, the address the earlier agent's host had. If that
  address changes, the rule in `mainnet-recovery-host.tf` has to follow.
  The bastion's and the recovery host's public addresses are not Elastic
  IPs and change on a stop and start.
- **The CloudFormation stacks.** Terraform holds them with the template in
  `files/quorums-cdn.yaml`. Their parameters are written in
  `modules/quorum-network/cdn.tf` but ignored until someone takes the
  `ignore_changes` line out, and the stacks carry no default tags: the file
  says why. Testnet's distribution differs from its template (the `/proofs`
  behaviour), so **any update of `quorums-cdn-testnet` that touches the
  distribution removes `/proofs`** unless the template has it by then.
- **Disk.** The quorum servers write an unrotated log to an 8 GiB disk. It
  filled mainnet's on 2026-10-30.
- **Not hardened, as found:** SSH to the bastion from anywhere; testnet
  Core's RPC port open to `10.0.0.0/8`; instance metadata version 1 allowed
  on every host; no termination protection on any instance; the listener's
  TLS policy is `ELBSecurityPolicy-2016-08`; port 80 open on the load
  balancer's security group with nothing listening.

## Leftovers to delete

Not in this stack, found beside it on 2026-11-20:

- CloudFormation stack `quorums-cdn-moutai` (distribution `EELLB9G4IZD5D`,
  health check `8ae38222-0a78-4331-ac8b-7b7e5c0172cc`, still probing every
  30 seconds) and its certificate `quorums.moutai.networks.dash.org`
  (`b67ae864-0038-4439-a38f-4a92b8902d52`). The devnet was destroyed on
  2026-10-01. Delete the stack first; the certificate is in use until then.
- A second VPC named `testnet-vpc` (`vpc-015da873851670a17`,
  `10.0.0.0/16`), with no subnets and no network interfaces.
- File system `fs-06e65a4b108ce69d9` (`us-east-1c`, 51 GB, no mount
  targets, made 2025-09-02 as a replication destination). Nothing uses it.
  What it is a copy of was not established.
