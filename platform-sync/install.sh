#!/bin/bash
# Builds the host side of platform-sync. Run as root from this directory.
# Safe to run again: it keeps the filesystem, the dashmate home and all data.
#
# Assembled from the commands used to build ubuntu-server-2 on 2026-11-20.
# Those commands were run step by step; this script as a whole has not been
# run on an empty host yet.
set -euo pipefail

S=/srv/platform-sync
SIZE=${SIZE:-120G}
DASHMATE_URL=${DASHMATE_URL:-https://github.com/dashpay/platform/releases/download/v5.1.0-dev.2/dashmate-v5.1.0-dev.2-3a5da22021-linux-x64.tar.gz}
# The mainnet observer on this host: the only peer the mainnet stack talks to.
OBSERVER_TD_RPC=${OBSERVER_TD_RPC:-http://127.0.0.1:26657}
TESTNET_SUBNET=172.30.24.0/24
MAINNET_SUBNET=172.30.25.0/24
MAINNET_GATEWAY=172.30.25.1
# The mounts are "nofail", which also means boot does not wait for them. Docker must:
# a container that starts first would bind the empty directory underneath instead.
BEFORE_DOCKER=x-systemd.before=docker.service
here=$(cd "$(dirname "$0")" && pwd)

dm() { DASHMATE_HOME_DIR=$S/home "$S/dashmate/bin/dashmate" "$@"; }

# 1. A filesystem of fixed size, so the sync can never fill the root disk.
if ! mountpoint -q "$S"; then
  if [ ! -e "$S.img" ]; then
    fallocate -l "$SIZE" "$S.img"
    chmod 600 "$S.img"
    mkfs.ext4 -q -m 0 -L platform-sync "$S.img"
  fi
  mkdir -p "$S"
  grep -q "^$S.img " /etc/fstab || echo "$S.img $S ext4 loop,nofail,noatime,$BEFORE_DOCKER 0 2" >> /etc/fstab
  systemctl daemon-reload
  mount "$S"
fi
mkdir -p "$S"/{dashmate,home,data,state,runs,bin,dl,runner} "$S"/spool/{requests,status/results} "$S"/ram/{testnet,mainnet}
# What the runner may write gets storage of its own, so that a job which fills it cannot
# take space from Core, the daemons' state or the results: a small disk filesystem for
# the runner's own directories, and 1 MiB of memory for the request spool (below).
if ! mountpoint -q "$S/runner"; then
  if [ ! -e "$S-runner.img" ]; then
    fallocate -l "${RUNNER_SIZE:-3G}" "$S-runner.img"
    chmod 600 "$S-runner.img"
    mkfs.ext4 -q -m 0 -L ps-runner "$S-runner.img"
  fi
  grep -q "^$S-runner.img " /etc/fstab || echo "$S-runner.img $S/runner ext4 loop,nofail,noatime,nodev,nosuid,$BEFORE_DOCKER 0 2" >> /etc/fstab
  systemctl daemon-reload
  mount "$S/runner"
fi
# Drive and Tenderdash state in memory, with a fixed size per network (see README, "Disk and memory").
for line in "tmpfs $S/ram/testnet tmpfs size=${TESTNET_STATE:-16g},mode=0700,noatime,nofail,$BEFORE_DOCKER 0 0" \
            "tmpfs $S/ram/mainnet tmpfs size=${MAINNET_STATE:-8g},mode=0700,noatime,nofail,$BEFORE_DOCKER 0 0" \
            "tmpfs $S/spool/requests tmpfs size=1m,nr_inodes=64,uid=1001,gid=0,mode=0730,noatime,nodev,nosuid,noexec,nofail,$BEFORE_DOCKER 0 0"; do
  grep -q "^tmpfs $(echo "$line" | cut -d' ' -f2) " /etc/fstab || echo "$line" >> /etc/fstab
done
systemctl daemon-reload
for m in ram/testnet ram/mainnet spool/requests; do mountpoint -q "$S/$m" || mount "$S/$m"; done
chmod 755 "$S" "$S/spool" "$S/spool/status" "$S/spool/status/results"
chmod 700 "$S"/{home,data,state,runs,runner}

# 2. dashmate, as a renderer of configuration. It is never used to start or stop anything.
if [ ! -x "$S/dashmate/bin/dashmate" ] || [ "$(cat "$S/dl/url" 2>/dev/null)" != "$DASHMATE_URL" ]; then
  curl -fsSL -o "$S/dl/dashmate.tgz" "$DASHMATE_URL"
  rm -rf "$S/dashmate" && mkdir -p "$S/dashmate"
  tar -xzf "$S/dl/dashmate.tgz" -C "$S/dashmate" --strip-components=1
  echo "$DASHMATE_URL" > "$S/dl/url"
fi
dm --version

# 3. Two configurations: full nodes with Platform, no masternode, nothing shared with other stacks.
for c in testnet mainnet; do
  dm config set core.masternode.enable false --config=$c
  dm config set platform.enable true --config=$c
  dm config set platform.drive.tenderdash.mode full --config=$c
  dm config set platform.drive.tenderdash.metrics.enabled true --config=$c
done
dm config set docker.network.subnet "$TESTNET_SUBNET" --config=testnet
dm config set docker.network.subnet "$MAINNET_SUBNET" --config=mainnet
dm config set core.docker.commandArgs '["-dbcache=2048"]' --config=testnet
# testnet has no local source. Each Tenderdash peer costs about 100 MB up and 35 MB down a day
# while the node follows the tip (measured 2026-11-21 with dashmate's default of 30), so keep few.
dm config set platform.drive.tenderdash.p2p.maxOutgoingConnections 4 --config=testnet
dm config set platform.drive.tenderdash.p2p.maxConnections 8 --config=testnet
# mainnet takes both chains from the observer on this host and from nowhere else.
observer_id=$(curl -fsS "$OBSERVER_TD_RPC/status" | python3 -c 'import sys,json; r=json.load(sys.stdin); r=r.get("result",r); print(r["node_info"]["id"])')
dm config set core.docker.commandArgs "[\"-connect=$MAINNET_GATEWAY:9999\",\"-dbcache=4096\"]" --config=mainnet
dm config set platform.drive.tenderdash.p2p.seeds '[]' --config=mainnet
dm config set platform.drive.tenderdash.p2p.persistentPeers "[{\"id\":\"$observer_id\",\"host\":\"$MAINNET_GATEWAY\",\"port\":26656}]" --config=mainnet
dm config set platform.drive.tenderdash.p2p.allowlistOnly true --config=mainnet
chmod 600 "$S/home/config.json"

install -m 644 "$here/compose.override.yml" "$S/compose.override.yml"
install -m 755 "$here/pscompose" "$S/bin/pscompose"
for c in testnet mainnet; do
  dm config render --config=$c
  (umask 077; dm config envs --config=$c > "$S/state/$c.env")
  mkdir -p "$S/data/$c/core" "$S/ram/$c"/{drive,tenderdash}
done
# Host ports for Tenderdash RPC and metrics (loopback). Kept if already there: they also hold the current images.
[ -e "$S/state/testnet.sync.env" ] || printf 'SYNC_TD_RPC_HOSTPORT=36657\nSYNC_TD_METRICS_HOSTPORT=36660\n' > "$S/state/testnet.sync.env"
[ -e "$S/state/mainnet.sync.env" ] || printf 'SYNC_TD_RPC_HOSTPORT=46657\nSYNC_TD_METRICS_HOSTPORT=46660\n' > "$S/state/mainnet.sync.env"

# 4. Core for both networks. The first sync takes hours; runs are refused until it is done.
for c in testnet mainnet; do "$S/bin/pscompose" $c up -d --no-deps core; done

# 5. The daemons.
install -d -m 755 /opt/platform-sync /etc/platform-sync
install -m 644 "$here/platform_sync.py" "$here/request.py" "$here/test_platform_sync.py" \
  "$here/release_watch.py" "$here/test_release_watch.py" /opt/platform-sync/
install -m 644 "$here/systemd/platform-sync@.service" /etc/systemd/system/platform-sync@.service
# The release watcher: asks for a replay of every new dev and rc release (README, "Releases").
install -m 644 "$here/systemd/platform-sync-release-watch.service" "$here/systemd/platform-sync-release-watch.timer" /etc/systemd/system/
# The firewall unit carries the mainnet subnet; change both together.
install -m 644 "$here/systemd/platform-sync-firewall.service" /etc/systemd/system/platform-sync-firewall.service
systemctl daemon-reload
systemctl enable --now platform-sync-firewall.service
systemctl enable --now platform-sync@testnet.service platform-sync@mainnet.service
systemctl enable --now platform-sync-release-watch.timer

# 6. The runner is registered separately, with a token: see runner/register.sh.
install -d -m 700 /opt/platform-sync-runner
install -m 644 "$here/runner/compose.yaml" /opt/platform-sync-runner/compose.yaml
install -m 755 "$here/runner/register.sh" /opt/platform-sync-runner/register.sh
echo "done. Core sync: $S/bin/pscompose <network> exec core dash-cli getblockchaininfo"
