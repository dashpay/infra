#!/usr/bin/env bash
# usage: rolling-backup.sh <label> live|cold [gap-seconds]
#   One validator at a time, the rest of the network keeps running.
#   live: copy while the node runs.   cold: stop Platform and Core on that node, copy, start again.
set -uo pipefail
cd "${DRILL_HOME:-$HOME/dr}"; D="python3 tools/drill.py"; L=$1; MODE=$2; GAP=${3:-45}
ts() { echo "=== $(date -u +%T) $*"; }
for n in $($D hosts | awk '$4=="validator"{print $1}'); do
  ts "$n"
  if [ "$MODE" = cold ]; then
    $D node "$n" quiesce | grep -E "td_height|td_app_hash" | tr '\n' ' '; echo
    $D node "$n" stop-core >/dev/null
  fi
  $D node "$n" backup "$MODE" "$L" | grep -E "td_height|td_app_hash|tar_rc|tar_warnings|bytes=" | tr '\n' ' '; echo
  if [ "$MODE" = cold ]; then
    $D node "$n" start-core >/dev/null
    for i in $(seq 1 30); do s=$($D node "$n" info | grep -E "core_synced|core_peers" | tr '\n' ' '); echo "$s" | grep -q "core_synced=true" && break; sleep 5; done; echo "   $s"
    $D node "$n" start-platform >/dev/null
  fi
  $D pull "$n" "$L" | cut -c1-80
  sleep "$GAP"
done
ts "done"
