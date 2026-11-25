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

## Releases: replayed without being asked

`release_watch.py` (timer `platform-sync-release-watch.timer`, every two
minutes) replays every **dev and rc release** of `dashpay/platform` on both
networks:

1. A new tag `vX.Y.Z-dev.N` or `vX.Y.Z-rc.N` appears in the releases feed. It
   says so in Slack; everything later about that release goes in the same
   thread.
2. It waits for CI: the `Release Drive image` jobs of the `Release Platform`
   run for that tag must all have succeeded, and `dashpay/drive:X.Y.Z-…` must
   be on Docker Hub for amd64. The rest of that workflow (NPM, SDKs, dashmate
   packages) takes hours longer and is not waited for.
3. It writes one request per network, naming that Drive image and the
   Tenderdash image dashmate ships at the same tag
   (`release-<version>-<network>`). A network that is replaying, or on hold,
   gets its request when it is free.
4. It posts each network's result when the daemon has written it.

What it does not do:

- **Stable releases** (`v5.1.0`) are not replayed: change `tag_pattern` for that.
- **Nothing published before its first run** is replayed. To follow one that
  is already out: `release_watch.py add --tag v5.1.0-rc.1`.
- A release that is still waiting when a newer one of the same `X.Y` line is
  published is dropped in favour of the newer one. A replay that has started
  is never interrupted; the next release waits for it.
- If CI ends without the image, it says so once and keeps looking for 72
  hours, so a rerun that publishes the image still starts the replay.

Why it asks instead of being told: the host has no public address, so a GitHub
webhook cannot reach it. New tags come from `releases.atom`, the image from
Docker Hub's API, and the state of CI from the GitHub API without a token
(two calls every five to ten minutes while a release waits, none otherwise). If GitHub
does not answer for 45 minutes while the image is already on Docker Hub, the
replay starts anyway and the message says that CI could not be read.

It runs as root but only writes its state (`state/release-watch.json`) and
request files, which pass the same checks as the runner's. The release title
and notes are never read. Slack goes through an MCP server with a
`post_message` tool; set it in `/etc/platform-sync/config.json`, and until
then the watcher only logs:

```json
{"release_watch": {"notify": {"mcp_url": "http://127.0.0.1:8787/mcp",
                              "bearer_file": "/etc/…/mcp-bearer", "channel": "C…"}}}
```

A message Slack did not take is sent on a later pass; it never holds up a
replay.

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

The `reason` of a result is published (status file, job summary, status
console), so it never carries a container's log lines or `docker compose`
output. The log line or error behind it is in
`runs/<network>/<id>/detail.txt` and in the daemon's journal, both readable
by root only. The one exception is an image that cannot be pulled: that is
reported with Docker's own error message.

Things the daemon does not give up on: a result file it could not write is
written again on every tick until it succeeds, services that did not stop
are stopped again before any new request is taken, and a request the daemon
had claimed when it died gets a `failed` result when it comes back.

## Disk and memory

Everything the sync keeps on disk lives in `/srv/platform-sync`, a fixed
120 GiB ext4 image (`/srv/platform-sync.img`, mounted through `/etc/fstab`).
It cannot grow into the root disk, and the daemons refuse to run if it is not
mounted.

| What | Where | Size (2026-11) | Grows |
|---|---|---|---|
| mainnet Core, full with txindex | disk | about 50 GB | about 0.5 GB a month |
| testnet Core | disk | about 5 GB | slowly |
| dashmate, logs of failed runs | disk | about 1 GB | bounded |
| the runner's own files | disk, a separate 3 GiB image | about 0.7 GB | bounded |
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
result and in `following`):

| Field | What it counts |
|---|---|
| `internetRx`, `internetTx` | Everything the stack exchanged with the internet, Core and Platform together, counted by the kernel. This is the figure to trust |
| `image` | Compressed size of the Drive image, if this run downloaded it |
| `platformRx`, `platformTx` | Tenderdash p2p message sizes from its metrics. Smaller than the wire traffic (see below), and on mainnet they are traffic with the local observer |
| `coreRx`, `coreTx` | Core p2p from `getnettotals`. On mainnet this is traffic with the local observer |

The internet figure comes from two counting rules per network that the
daemon keeps in Docker's `DOCKER-USER` chain (comment
`platform-sync-<network>-in` / `-out`, no target): bytes forwarded between
the stack's subnet and anything outside `172.16.0.0/12`. Tenderdash's own
byte metrics are not used for it. They count message sizes: on 2026-11-21
a node following the tip moved 3 times (up) and 15 times (down) what the
metrics said, measured per TCP socket (the likely reason is the encrypted
connection's fixed 1 kB frames; not confirmed). They also book each
received message a second time as "sent" under an empty `peer_id`.

- **mainnet**: both chains come from the mainnet observer that already runs
  on this host, and from nowhere else. Core is started with `-connect=`, and
  Tenderdash has the observer as its persistent peer. Tenderdash 2.0.0-dev.3
  still dials the other peers it learns about, `allowlist-only` or not, so
  `platform-sync-firewall.service` adds one rule to Docker's `DOCKER-USER`
  chain: nothing from the mainnet stack's subnet is forwarded outside Docker's
  private range. A mainnet replay uses no internet data beyond the image.
- **testnet**: there is no local source, so the blocks come from the public
  network. Two costs:
  - **A replay**: 1.6 GB of block messages at height 719,000 (first run,
    2026-11-20), growing with the chain. That run predates the internet
    counters; its wire total was below 2.9 GB. `internetRx` of the next
    run is the exact figure.
  - **Following the tip between runs** costs more over a month than the
    replays do, and it grows with the number of Tenderdash peers. With
    dashmate's default of 30 outgoing peers the stack moved about 3.0 GB
    up and 1.0 GB down a day, a third of the upload being answers to
    peer-exchange requests. `install.sh` therefore sets
    `maxOutgoingConnections` to 4 (`maxConnections` 8): measured right
    after, 0.32 GB up and 0.19 GB down a day for the whole stack, Core
    included (five-minute samples on 2026-11-21, a quiet hour on testnet).
    Whether four peers slow a replay down has not been measured yet; the
    first one ran at 85 blocks a second with 30.

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

# the release watcher: what it follows, what it would do now, its log
sudo python3 /opt/platform-sync/release_watch.py status
sudo python3 /opt/platform-sync/release_watch.py tick --dry-run
journalctl -u platform-sync-release-watch -n 50
sudo systemctl disable --now platform-sync-release-watch.timer   # switch it off
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

What the runner can write on the host has storage of its own, so a job that
fills it takes nothing from Core, the daemons' state or the results:

| Path on the host | In the runner | Storage |
|---|---|---|
| `/srv/platform-sync/spool/requests` | `/spool/requests` | tmpfs, 1 MiB and 64 files. Emptied by a reboot; a request waiting at that moment is lost |
| `/srv/platform-sync/runner` | `/runner`, `/work` | its own 3 GiB filesystem (`/srv/platform-sync-runner.img`) |

Not bounded: the container's own writable layer (`/tmp`, the home
directory), which Docker keeps on the host's root filesystem like that of
every other runner container on this host.

Root writes into the request spool too (`platform_sync.py request`). It
creates its temporary file exclusively under a random name and never
follows a link there.

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
| `release_watch.py` | Asks for a replay of every new dev and rc release, and reports it |
| `systemd/platform-sync-release-watch.{service,timer}` | Runs it every two minutes |
| `compose.override.yml` | Data location, ports, log and resource caps |
| `pscompose` | `docker compose` for one stack, for people |
| `systemd/platform-sync@.service` | One daemon per network |
| `systemd/platform-sync-firewall.service` | Keeps the mainnet stack off the internet |
| `runner/` | The runner container and its registration |
| `install.sh` | Builds the host side from nothing |
| `test_platform_sync.py`, `test_release_watch.py` | `python3 -m unittest platform-sync/test_platform_sync.py platform-sync/test_release_watch.py` |
