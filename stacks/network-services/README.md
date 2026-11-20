# network-services

Mainnet Insight and the two DNS seeders. All of it was moved from the old
`dashevo` account on 2026-11-20 (#19), built by hand and by script, and
adopted here as it runs.

Every host is in the account's default VPC and has no SSH. Reach one with
SSM Session Manager: `aws ssm start-session --target <instance id>`.

## What is here

### Mainnet Insight

`insight.dash.org`, `explorer.dash.org`, `api.dash.org` and
`insight.dashevo.org`: the public block explorer and its API for Dash
mainnet. One host, one load balancer.

| File | What |
|---|---|
| `insight.tf` | The host `insight-mainnet` (`m7a.large`, `us-west-2d`), its role `insight-ssm`, its security group, the 150 GB data volume, the Elastic IP `68.67.122.192`, and the image a new host is built from |
| `insight-lb.tf` | The load balancer `insight-mainnet`, its listeners (80 and 443), target group, security group and certificate, and the record `insight.dashevo.org` |
| `files/insight-user-data.yaml` | The host's first-boot instructions |

On the host (Ubuntu 20.04), `/home/ubuntu/docker-compose.yml` runs two
containers: `dashcore` (`dashpay/dashd:22`) and `insight`
(`dashpay/insight:4.0.10`). Their configuration, `dash.conf` and
`dashcore-node.json`, is beside the compose file. The load balancer talks to
Insight on port 3001. nginx on the host's port 80 only serves a 404 and is
not used.

The data volume is mounted at `/mnt` and is Core's data directory: the block
files, the chain state and the address, transaction and spent indexes that
Insight reads through Core. Insight keeps no database of its own. On
2026-11-20 it held 112 GB.

### DNS seeders

`dnsseed.tf`: `dnsseed-mainnet` (`68.67.122.246`) and `dnsseed-testnet`
(`68.67.122.247`), their shared role `dnsseed-ssm` and security group
`dnsseed` (UDP 53 in). Each is a `t4g.micro` running one container,
`nmarley/dnsseed:0.1.6-alpine`, from `/opt/dnsseed/docker-compose.yml`. The
seeder crawls the network and answers DNS with addresses of reachable nodes.
It stores nothing.

`files/dnsseed-user-data.sh.tftpl` is the first-boot script. Rendered, it is
byte for byte what the two running seeders were built with.

To check a seeder: `dig +short dnsseed.dash.org @68.67.122.246` (testnet:
`test-dnsseed.dash.org @68.67.122.247`) returns about 25 addresses.

## What is not here

- **The `dash.org` names.** `dash.org` is a Cloudflare zone, changed by
  hand. It must say:

  | Name | Record |
  |---|---|
  | `insight.dash.org`, `explorer.dash.org` | CNAME to the load balancer (output `insight.load_balancer`), proxied |
  | `api.dash.org` | CNAME to the load balancer, not proxied |
  | Three `_<hash>.<name>.dash.org` names | CNAMEs that keep the certificate renewing (output `insight.certificate_validation`) |
  | `seed.dash.org` | A `68.67.122.246` |
  | `dnsseed.dash.org` | NS `seed.dash.org` |
  | `test-seed.dash.org` | A `68.67.122.247` |
  | `test-dnsseed.dash.org` | NS `test-seed.dash.org` |

- **The zone `dashevo.org`**: the `dns` stack. This stack owns two records
  in it: `insight.dashevo.org` and the certificate's validation record for
  that name.
- **The default VPC and its subnets**: nobody's. They are looked up.
- **The address pool**: the `account` stack.
- **What runs on the hosts.** Terraform makes a host and hands it a
  first-boot script. The containers, their versions and their configuration
  on the Insight host are changed on the host. Nothing here deploys to it.
- **The two snapshots behind the image** (`snap-0f482eefe10834fb3`, the
  root disk; `snap-03b031047841d6bbf`, the chain data). The image names
  them, and AWS refuses to delete a snapshot while its image exists.

## Rebuild from nothing

Needs the `account` stack (address pool) and the `dns` stack (zone
`dashevo.org`). Delete `imports.tf`, then `terraform apply`.

### The seeders

Terraform recreates everything. A new seeder needs nothing but its address:
it installs Docker, starts the container and has a full list of nodes within
minutes (under three on 2026-11-20). To replace one that misbehaves:

```sh
terraform apply -replace='aws_instance.dnsseed["testnet"]'
```

The address stays, so nothing at Cloudflare changes.

What would be lost: nothing, as long as the two addresses are kept. If an
Elastic IP itself is released, Terraform allocates another from the pool and
the A record at Cloudflare has to be changed to it.

### Insight

How much has to be restored depends on what is lost.

**The host is lost, the data volume is not.** `terraform apply` launches a
new host from the image, attaches the data volume, moves the address and
registers the host with the load balancer. No chain data has to be copied or
synced. Then:

- The root disk is the old host as it was on **2026-11-20 13:32 UTC**.
  Anything changed on the host after that (a Core or Insight upgrade,
  `dash.conf`, the compose file) is gone and has to be done again. **After
  changing the host, make a new image of it** and put its id and snapshot
  ids in `insight.tf`; nothing makes one automatically.
- The first boot waits 60 seconds for the data volume. Terraform attaches it
  only once the instance runs, which can be later. If `/mnt` is empty and
  Docker is not running, start them through SSM: `sudo mount /mnt && sudo
  systemctl start docker`.
- This path has not been tried.

**The data volume is lost too** (or the whole zone: change
`local.insight_zone`). Terraform makes a new volume from the image's
snapshot: the chain as Core had it on 2026-11-20 13:32 UTC. Two things then
take time, and both were measured when the host was moved on 2026-11-20:

1. *A volume made from a snapshot is slow until every block of it has been
   read once.* Until then Core answers too slowly for Insight and most
   requests fail, while the load balancer still shows the host as healthy.
   Read the whole device through SSM, in parallel. With 24 readers, 150 GB
   took 101 minutes; one reader manages 7 MB/s, which would be about six
   hours. For example, after checking the device name with `lsblk`:

   ```sh
   for i in $(seq 0 23); do
     sudo dd if=/dev/nvme1n1 of=/dev/null bs=1M iflag=direct skip=$((i * 6400)) count=6400 &
   done; wait
   ```

2. *Core catches up.* It first replays what it had not flushed when the
   image was taken (490 blocks, 78 minutes on the still-loading volume),
   then downloads every block made since. On 2026-11-20 that was four hours
   of blocks. For an older image it is longer, and how much longer has not
   been measured.

On 2026-11-20 the new host was launched at 16:10 UTC and answered like the
old one at 18:01: **about two hours**, with an image under three hours old. Do not
point clients at a rebuilt host before `/insight-api/sync` reports the
current height and a few address and block requests answer in about a
second.

**The image and its snapshots are lost as well.** Then nothing restores the
host. It has to be built by hand (Ubuntu, Docker, the compose file and
configuration described above) and Core has to sync mainnet from the first
block with its indexes on. Expect days; it has not been measured.
The compose file and `dash.conf` exist only on the host and in the image.

**The certificate.** A new certificate is issued only after its validation
records exist. Terraform creates the one in `dashevo.org`. The three for the
`dash.org` names have to be put into Cloudflare by hand (output
`insight.certificate_validation`), and the first `terraform apply` fails at
the HTTPS listener until that is done and the certificate is issued. Run it
again then. A new load balancer has a new name: update the three CNAMEs at
Cloudflare.

## What an operator must know

- **Insight is one host in one zone.** There is no second host and no
  scheduled snapshot of either disk. The image of 2026-11-20 is the only
  restore point, and it gets older every day.
- **The data volume is still marked "delete on termination"** on the running
  instance, because it was created with the instance and not on its own.
  Terminating the instance in the console or the API deletes the chain data
  with it. Termination protection is on and must stay on. The flag can be
  cleared without stopping anything:

  ```sh
  aws ec2 modify-instance-attribute --instance-id i-073cce4ac3c49b6f6 \
    --block-device-mappings '[{"DeviceName":"/dev/sdf","Ebs":{"DeleteOnTermination":false}}]'
  ```

- **The health check accepts any status from 200 to 499.** It shows whether
  Insight's port answers, not whether Insight works. Use
  `https://insight.dash.org/insight-api/sync` to see that.
- **The load balancer can be deleted**: deletion protection is off.
- The load balancer's addresses are Amazon's, not from the owned pool. No
  DNS record names them directly.
- Port 80 forwards to Insight like port 443. It does not redirect to HTTPS.
- The seeders answer on UDP only.
