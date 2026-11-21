#!/usr/bin/env bash
# Backup and restore of one console-devnet validator (dash-network-go layout).
# Run as root on the node; drill.py does that for a whole fleet.
#
#   dr-node.sh info                       state of the node, one key=value per line
#   dr-node.sh block <height>             "height block_hash app_hash" as committed on this node
#   dr-node.sh chainlocks <height>...     does the chain lock in each Platform block name a block on this node's Core chain
#   dr-node.sh quiesce                    print the committed height and hashes, then stop Platform
#   dr-node.sh stop-platform              stop Tenderdash, then DAPI, gateway, Drive
#   dr-node.sh start-platform             start Drive, then Tenderdash, DAPI, gateway
#   dr-node.sh stop-core | start-core
#   dr-node.sh flush-core                 write Core's chain state to disk now (before a volume snapshot)
#   dr-node.sh miner stop|start           on the wallet host: pause or resume mining
#   dr-node.sh logs <service> [lines]     tail of one container's log
#   dr-node.sh backup cold|live <label>   write /var/tmp/dr/<label>.tar.gz
#       cold: Platform and Core must already be stopped (the caller coordinates)
#       live: copy while everything runs
#   dr-node.sh wreck                      DESTRUCTIVE, for rehearsals: stop Platform, wipe its two volumes and its config
#   dr-node.sh restore <archive> platform|platform+llmq
#       Platform must be stopped; for platform+llmq Core must be stopped too.
#       platform+llmq halts Platform when the copy is older than a few minutes: see ../README.md
#
# Backup scope: /var/lib/dashnet (node config, node key, genesis, TLS, secrets),
# the Tenderdash volume, the Drive volume, Core's llmq directory.
set -euo pipefail

core=$(docker ps -a --format '{{.Names}}' | grep -E -- '-core$' | head -1)
[ -n "$core" ] || { echo "no core container" >&2; exit 1; }
project=${core%-core}
node=${project#dashnet-*-}
vol=/var/lib/docker/volumes
td_vol=$vol/${project}_drive_tenderdash/_data
drive_vol=$vol/${project}_drive_abci_data/_data
core_vol=$vol/${project}_core_data/_data
llmq=$(find "$core_vol/.dashcore" -maxdepth 2 -type d -name llmq | head -1)
cfg=/var/lib/dashnet
platform_cfg=$cfg/dashmate/$node/platform
work=/var/tmp/dr
# Stop order: Tenderdash first, so it never sees Drive's socket close.
platform_stop="drive_tenderdash rs_dapi gateway gateway_rate_limiter drive_abci"
platform_start="drive_abci drive_tenderdash rs_dapi gateway_rate_limiter gateway"

cli() { docker exec "$core" dash-cli "$@"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$project-$1" 2>/dev/null)" = true ]; }
rpc() { curl -s -m 5 "127.0.0.1:26657/$1"; }

info() {
  echo "node=$node"
  echo "time=$(date -u +%FT%TZ)"
  for s in core drive_abci drive_tenderdash rs_dapi gateway; do
    docker inspect -f "c_$s={{.State.Status}} id={{slice .Id 0 12}} started={{.State.StartedAt}} restarts={{.RestartCount}}" "$project-$s" 2>/dev/null || echo "c_$s=absent"
  done
  if running core; then
    echo "core_height=$(cli getblockcount 2>/dev/null || echo ?)"
    echo "core_chainlock=$(cli getbestchainlock 2>/dev/null | sed -n 's/.*"height": \([0-9]*\).*/\1/p')"
    echo "mn_state=$(cli masternode status 2>/dev/null | sed -n 's/.*"state": "\([A-Z_]*\)".*/\1/p' | head -1)"
    echo "core_synced=$(cli mnsync status 2>/dev/null | sed -n 's/.*"IsSynced": \([a-z]*\).*/\1/p')"
    echo "core_peers=$(cli getconnectioncount 2>/dev/null)"
  fi
  if running drive_tenderdash; then
    rpc status | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); d = d.get("result", d); s = d["sync_info"]
    print("td_height=%s" % s["latest_block_height"]); print("td_block_hash=%s" % s["latest_block_hash"])
    print("td_app_hash=%s" % s["latest_app_hash"]); print("td_earliest=%s" % s["earliest_block_height"])
    print("td_catching_up=%s" % s["catching_up"]); print("td_block_time=%s" % s["latest_block_time"])
    print("td_version=%s" % d["node_info"]["version"])
except Exception as e:
    print("td_error=%r" % e)
' || true
    rpc validators | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); d = d.get("result", d)
    print("td_validators=%d" % len(d.get("validators", []))); print("td_quorum=%s" % str(d.get("quorum_hash", "")).lower())
except Exception as e:
    print("td_validators_error=%r" % e)
' || true
    rpc net_info | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); d = d.get("result", d); print("td_peers=%s" % d.get("n_peers"))
except Exception as e:
    print("td_peers_error=%r" % e)
' || true
  fi
  echo "du_tenderdash=$(du -sm "$td_vol" | cut -f1)M du_drive=$(du -sm "$drive_vol" | cut -f1)M du_llmq=$(du -sm "$llmq" | cut -f1)M du_cfg=$(du -sm "$cfg" | cut -f1)M"
}

block() { # block <height>: "height block_hash app_hash" as committed on this node
  rpc "block?height=$1" | python3 -c '
import sys, json
d = json.load(sys.stdin); d = d.get("result", d)
print(d["block"]["header"]["height"], d["block_id"]["hash"], d["block"]["header"]["app_hash"])
' 2>/dev/null || echo "$1 unavailable unavailable"
}

flush_core() {
  # gettxoutsetinfo forces a full flush (ForceFlushStateToDisk). Without it a running Core
  # writes its block index hourly and its chain state daily, so a snapshot is that far behind.
  cli gettxoutsetinfo | python3 -c 'import sys, json; d = json.load(sys.stdin); print("flushed height=%s bestblock=%s" % (d["height"], d["bestblock"]))'
  sync
}

chainlocks() {
  python3 - "$core" "$@" <<'PY'
import base64, json, subprocess, sys, urllib.request
core = sys.argv[1]
for h in sys.argv[2:]:
    d = json.load(urllib.request.urlopen("http://127.0.0.1:26657/block?height=%s" % h, timeout=5)); d = d.get("result", d)
    lock = d["block"].get("core_chain_lock") or {}
    if not lock:
        print("platform=%s chain_lock=none" % h); continue
    want = base64.b64decode(lock["core_block_hash"])[::-1].hex()
    have = subprocess.run(["docker", "exec", core, "dash-cli", "getblockhash", str(lock["core_block_height"])], capture_output=True, text=True).stdout.strip()
    print("platform=%s core=%s locked=%s on_chain=%s same=%s" % (h, lock["core_block_height"], want[:16], have[:16] or "none", want == have))
PY
}

stop_platform() { for s in $platform_stop; do docker stop -t 30 "$project-$s" >/dev/null 2>&1 || true; done; }
start_platform() { for s in $platform_start; do docker start "$project-$s" >/dev/null; if [ "$s" = drive_abci ]; then sleep 5; fi; done; }

backup() {
  local mode=$1 label=$2 out=$work/$2.tar.gz m=$work/$2.manifest
  mkdir -p "$work"; chmod 700 "$work"
  if [ "$mode" = cold ]; then
    for s in drive_tenderdash drive_abci core; do running $s && { echo "cold backup: $s is still running" >&2; exit 1; }; done
  fi
  {
    echo "label=$label"; echo "mode=$mode"; echo "node=$node"; echo "project=$project"
    echo "started=$(date -u +%FT%TZ)"
    echo "tenderdash_volume=$td_vol"; echo "drive_volume=$drive_vol"; echo "llmq=$llmq"; echo "config=$cfg"
    [ "$mode" = live ] && info | grep -E '^(td_|core_|mn_)' || true
    for s in core drive_abci drive_tenderdash rs_dapi gateway; do docker inspect -f "image_$s={{.Image}}" "$project-$s"; done
  } > "$m"
  # tar exit 1 means "a file changed while it was read": expected in live mode, recorded, never in cold mode.
  set +e
  tar -C / --warning=no-file-ignored -czf "$out" "${cfg#/}" "${td_vol#/}" "${drive_vol#/}" "${llmq#/}" 2> "$work/$label.tar.err"
  local rc=$?
  set -e
  echo "tar_rc=$rc" >> "$m"; echo "tar_warnings=$(wc -l < "$work/$label.tar.err")" >> "$m"; echo "finished=$(date -u +%FT%TZ)" >> "$m"
  [ "$rc" -le 1 ] || { cat "$work/$label.tar.err" >&2; exit "$rc"; }
  [ "$mode" = cold ] && [ "$rc" -ne 0 ] && { echo "cold backup changed while reading" >&2; exit 1; }
  echo "sha256=$(sha256sum "$out" | cut -d' ' -f1)" >> "$m"; echo "bytes=$(stat -c %s "$out")" >> "$m"
  cat "$m"
}

wreck() {
  stop_platform
  find "$td_vol" "$drive_vol" -mindepth 1 -delete
  rm -rf "$platform_cfg"
  echo "wrecked=$node tenderdash=$(du -sk "$td_vol" | cut -f1)K drive=$(du -sk "$drive_vol" | cut -f1)K platform_cfg=$([ -e "$platform_cfg" ] && echo present || echo gone)"
}

restore() {
  local archive=$1 scope=$2 tmp
  for s in drive_tenderdash drive_abci; do running $s && { echo "restore: $s is running" >&2; exit 1; }; done
  [ "$scope" = platform+llmq ] && running core && { echo "restore with llmq: core is running" >&2; exit 1; }
  tmp=$(mktemp -d "$work/restore.XXXXXX")
  tar -C "$tmp" -xzf "$archive"
  # Volumes: replace contents, keep the volume directory itself (Docker owns it).
  for d in "$td_vol" "$drive_vol"; do
    find "$d" -mindepth 1 -delete
    cp -a "$tmp$d/." "$d/"
  done
  # Platform config of this node only; the rest of /var/lib/dashnet is left as it is.
  rm -rf "$platform_cfg"; mkdir -p "$(dirname "$platform_cfg")"
  cp -a "$tmp$platform_cfg" "$platform_cfg"
  if [ "$scope" = platform+llmq ]; then
    find "$llmq" -mindepth 1 -delete
    cp -a "$tmp$llmq/." "$llmq/"
  fi
  rm -rf "$tmp"
  # The ACME container holds the old TLS directory open; give it the restored one.
  docker restart "$project-acme" >/dev/null 2>&1 || true
  echo "restored=$node scope=$scope tenderdash=$(du -sm "$td_vol" | cut -f1)M drive=$(du -sm "$drive_vol" | cut -f1)M"
}

case "${1:-}" in
  info) info ;;
  block) block "$2" ;;
  quiesce) info | grep -E '^(time|td_height|td_block_hash|td_app_hash|td_quorum|core_height)='; stop_platform; echo "platform stopped on $node" ;;
  logs) docker logs --tail "${3:-40}" "$project-$2" 2>&1 ;;
  miner) m=$(docker ps -a --format '{{.Names}}' | grep -E -- '-miner$'); docker "$2" "$m" >/dev/null; echo "miner $2: $(docker inspect -f '{{.State.Status}}' "$m") core_height=$(cli getblockcount)" ;;
  stop-platform) stop_platform; echo "platform stopped on $node" ;;
  start-platform) start_platform; echo "platform started on $node" ;;
  flush-core) flush_core ;;
  chainlocks) shift; chainlocks "$@" ;;
  stop-core) docker stop -t 120 "$core" >/dev/null; echo "core stopped on $node" ;;
  start-core) docker start "$core" >/dev/null; echo "core started on $node" ;;
  backup) backup "$2" "$3" ;;
  wreck) wreck ;;
  restore) restore "$2" "$3" ;;
  *) echo "usage: dr-node.sh info|block|chainlocks|quiesce|stop-platform|start-platform|stop-core|start-core|flush-core|miner|logs|backup|wreck|restore (see the head of the script)" >&2; exit 2 ;;
esac
