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
  grep -q "^$S.img " /etc/fstab || echo "$S.img $S ext4 loop,nofail,noatime 0 2" >> /etc/fstab
  systemctl daemon-reload
  mount "$S"
fi
mkdir -p "$S"/{dashmate,home,data,state,runs,bin,dl} "$S"/spool/{requests,status/results} "$S"/ram/{testnet,mainnet}
# Drive and Tenderdash state in memory, with a fixed size per network (see README, "Disk and memory").
for line in "tmpfs $S/ram/testnet tmpfs size=${TESTNET_STATE:-16g},mode=0700,noatime,nofail 0 0" \
            "tmpfs $S/ram/mainnet tmpfs size=${MAINNET_STATE:-8g},mode=0700,noatime,nofail 0 0"; do
  grep -q "^tmpfs $(echo "$line" | cut -d' ' -f2) " /etc/fstab || echo "$line" >> /etc/fstab
done
systemctl daemon-reload
for n in testnet mainnet; do mountpoint -q "$S/ram/$n" || mount "$S/ram/$n"; done
chmod 755 "$S" "$S/spool" "$S/spool/status" "$S/spool/status/results"
chmod 700 "$S"/{home,data,state,runs}
chown 1001:0 "$S/spool/requests"
chmod 0730 "$S/spool/requests"

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
install -m 644 "$here/platform_sync.py" "$here/request.py" "$here/test_platform_sync.py" /opt/platform-sync/
install -m 644 "$here/systemd/platform-sync@.service" /etc/systemd/system/platform-sync@.service
# The firewall unit carries the mainnet subnet; change both together.
install -m 644 "$here/systemd/platform-sync-firewall.service" /etc/systemd/system/platform-sync-firewall.service
systemctl daemon-reload
systemctl enable --now platform-sync-firewall.service
systemctl enable --now platform-sync@testnet.service platform-sync@mainnet.service

# 6. The runner is registered separately, with a token: see runner/register.sh.
install -d -m 700 /opt/platform-sync-runner
install -m 644 "$here/runner/compose.yaml" /opt/platform-sync-runner/compose.yaml
install -m 755 "$here/runner/register.sh" /opt/platform-sync-runner/register.sh
echo "done. Core sync: $S/bin/pscompose <network> exec core dash-cli getblockchaininfo"
