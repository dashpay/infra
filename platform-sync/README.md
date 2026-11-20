# platform-sync

Replays Dash Platform from genesis on testnet and on mainnet, every night a
new Drive version exists, and reports whether the node reached the network's
tip. It answers one question before a release does: *can this version still
sync the real chains from block 1?*

It runs on one machine we already own (`ubuntu-server-2`), not on AWS
([#26](https://github.com/dashpay/infra/issues/26)).

## How it fits together

```
GitHub Actions (.github/workflows/platform-sync.yml, nightly or by hand)
        │ job runs on the runner container below
        ▼
platform-sync-runner ── writes ──▶ /srv/platform-sync/spool/requests/<id>.json
   (no Docker socket,  ◀─ reads ── /srv/platform-sync/spool/status/…
    no secrets)
                                        ▲ │
                 platform-sync@testnet ─┘ │  one daemon per network (platform_sync.py)
                 platform-sync@mainnet ───┘
                                        │ docker compose
                                        ▼
        per network: core (kept) + drive_abci + drive_tenderdash (wiped each run)
```

- **Core is long-lived.** Each network has its own Core container that stays
  synced. A run never touches it.
- **A run** stops Drive and Tenderdash, deletes their data, starts them with
  the requested Drive image and watches until the node is at the tip.
- **Between runs** the node keeps following the tip, and the daemon keeps
  `spool/status/<network>.json` current (height, image, last result).
- The containers are dashmate's own compose services. dashmate (a release
  tarball in `/srv/platform-sync/dashmate`, with its own home directory)
  renders the configuration; `compose.override.yml` moves the data (Core to a
  fixed-size disk filesystem, Platform state to memory), removes the
  published ports and caps logs, CPU and memory.

## What "auto" runs

The newest published tag of `dashpay/drive` that looks like a release,
prereleases included (`5.1.0-dev.2`, `5.1.0-rc.1`, `5.1.0`), with the
Tenderdash image dashmate ships for that same tag. If that image already
passed and the node is still following, the night is skipped.

The per-commit images that Platform CI builds are **not** usable: they are
dev-profile builds that write SDK test data into the genesis state
(`SDK_TEST_DATA=true`), so their state never matches a real network. A true
per-commit nightly needs Platform CI to publish a release-profile Drive image
without test data; pass such an image as `image` once it exists.

## Pass and fail

A run **passes** when Tenderdash reports it is no longer catching up, its
height is within 2 blocks of the reference, and it then follows 3 more blocks.
Tenderdash refuses a block whose AppHash differs from what Drive computed, so
reaching the tip from genesis means every block's state matched.

- Reference for testnet: the highest Platform height on the status console's
  public API. Reference for mainnet: the local mainnet observer's Tenderdash,
  and there one block's hash and AppHash are compared as well.

A run **fails** on: an AppHash mismatch or consensus failure in the logs, a
container that is gone, out of memory or restarted 5 times, no new block for
30 minutes, 20 hours without reaching the tip, or running out of its disk or
memory allowance.
On failure Drive and Tenderdash are stopped and **their data is left in
place** until the next run starts or the host reboots; the last 3,000 log
lines of each are saved under `runs/<network>/<id>/`.

## Disk and memory

Everything the sync keeps on disk lives in `/srv/platform-sync`, a fixed
120 GiB ext4 image (`/srv/platform-sync.img`, mounted through `/etc/fstab`).
It cannot grow into the root disk, and the daemons refuse to run if it is not
mounted.

| What | Where | Size (2026-11) | Grows |
|---|---|---|---|
| mainnet Core, full with txindex | disk | about 50 GB | about 0.5 GB a month |
| testnet Core | disk | about 5 GB | slowly |
| dashmate, runner, logs of failed runs | disk | about 2 GB | bounded |
| testnet Platform state (Tenderdash + Drive) | memory, 16 GiB at most | about 5 GB | with the chain; rewritten each run |
| mainnet Platform state | memory, 8 GiB at most | about 2.5 GB | with the chain; rewritten each run |

**The Platform state is held in memory**, in one tmpfs per network
(`/srv/platform-sync/ram/<network>`, sized in `/etc/fstab`). A replay syncs to
disk several times for every block, and this host's NVMe takes 8 to 30 ms for
each: on disk the replay ran at 12 blocks a second, in memory at 58. The state
is rebuilt by every run, so nothing of value is at risk. What it costs:

- A reboot empties it. The daemon notices the node restarting from block 1,
  stops it, and the next run rebuilds it.
- The memory is charged to the Drive and Tenderdash containers, which is why
  their limits are 20 GiB each.
- When a chain outgrows its tmpfs the run fails and says so; raise `size=` in
  `/etc/fstab` and `mount -o remount`.

A run needs 15 GiB of disk free to start and is stopped below 5 GiB. Outside
these filesystems the sync leaves only Docker images (a few hundred MB each;
the daemon removes the ones it pulled once no container uses them) and
container logs (capped at 200 MB per container).

To grow the disk image: `truncate -s <new>G /srv/platform-sync.img`,
`losetup -c` on its loop device, `resize2fs` the device. Online, no restart.

## Network data

The host is on a satellite link, so the stacks are set up to move as
little as possible, and every run records what it moved (`bytes` in the
result: Tenderdash p2p from its metrics, Core from `getnettotals`, and the
compressed image size if it was downloaded).

- **mainnet**: both chains come from the mainnet observer that already runs
  on this host, and from nowhere else. Core is started with `-connect=`, and
  Tenderdash has the observer as its persistent peer. Tenderdash 2.0.0-dev.3
  still dials the other peers it learns about, `allowlist-only` or not, so
  `platform-sync-firewall.service` adds one rule to Docker's `DOCKER-USER`
  chain: nothing from the mainnet stack's subnet is forwarded outside Docker's
  private range. A mainnet replay uses no internet data beyond the image.
- **testnet**: there is no local source, so the blocks come from the public
  network: about 3 GB for a replay at height 720,000, growing with the chain.

## Operating it

```sh
# where things are
sudo python3 /opt/platform-sync/platform_sync.py status --network testnet
journalctl -u platform-sync@testnet -f
sudo /srv/platform-sync/bin/pscompose testnet ps          # docker compose for one stack
sudo /srv/platform-sync/bin/pscompose testnet logs --tail 100 drive_tenderdash

# run one from the host instead of from GitHub
sudo python3 /opt/platform-sync/platform_sync.py request --network testnet --image dashpay/drive:5.1.0-dev.2 --force

# keep the next run from wiping a failed node while somebody looks at it
sudo python3 /opt/platform-sync/platform_sync.py hold --network testnet "Ivan is reading the stores"
sudo python3 /opt/platform-sync/platform_sync.py release --network testnet
```

From GitHub: *Actions → Platform sync → Run workflow*, with a network and an
image. Accepted images are `dashpay/drive:<tag>`, `dashpay/drive@sha256:…`
and anything under `ghcr.io/dashpay/`; everything else is refused.

Settings are the `DEFAULTS` at the top of `platform_sync.py`; put overrides
in `/etc/platform-sync/config.json` (same shape) and restart the daemon.

### Moving to a newer dashmate

The configuration templates come from the dashmate tarball, and the daemons
only take the Tenderdash *image* from the release being tested. When a
release changes the templates, install its tarball: rerun `install.sh` with
`DASHMATE_URL` set. It keeps the dashmate home, re-renders both configurations
and rewrites `state/<network>.env`. Nothing restarts until the next run.

## The runner and what it may do

`dashpay/infra` is a public repository, so the runner is built to be harmless
if a workflow it runs is hostile: no Docker socket, all capabilities dropped,
1 CPU and 2 GiB, no secrets, and the job token has no permissions. Its whole
reach into the host is a directory it can write request files into and a
read-only view of the status files. `platform_sync.py` reads a request with
`O_NOFOLLOW`, refuses anything that is not a small regular JSON file, and
checks the network and the image reference against a fixed pattern before
Docker sees them (`test_platform_sync.py`). The worst a bad request can do is
start a replay of an image published by `dashpay`.

Cancelling the GitHub job stops the waiting, not the replay.

## Limits worth knowing

- One host. If it is down, the night is missed and the status goes stale.
- The mainnet stack depends on the local mainnet observer for both chains. If
  the observer is reset, its Tenderdash node id changes and
  `platform.drive.tenderdash.p2p.persistentPeers` must be set again.
- Testnet has no independent AppHash comparison at the tip; mainnet has.
- The runner software is pinned in the runner image and does not update
  itself. GitHub stops serving runners that are too old.
- GitHub disables scheduled workflows in a repository with no activity for
  60 days.

## Files

| File | What |
|---|---|
| `platform_sync.py` | The daemon and its command line |
| `request.py` | The client the workflow runs inside the runner |
| `compose.override.yml` | Data location, ports, log and resource caps |
| `pscompose` | `docker compose` for one stack, for people |
| `systemd/platform-sync@.service` | One daemon per network |
| `systemd/platform-sync-firewall.service` | Keeps the mainnet stack off the internet |
| `runner/` | The runner container and its registration |
| `install.sh` | Builds the host side from nothing |
| `test_platform_sync.py` | `python3 -m unittest platform-sync/test_platform_sync.py` |
