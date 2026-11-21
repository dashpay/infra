#!/usr/bin/env bash
# usage: restore-fleet.sh <label> platform|platform+llmq [watch-seconds]
#   Restores every validator from archives/<label>.<node>.tar.gz and starts Platform.
#   platform       Core keeps running with its live llmq directory
#   platform+llmq  Core is stopped on every validator and its llmq directory is replaced
set -uo pipefail
cd "${DRILL_HOME:-$HOME/dr}"; D="python3 tools/drill.py"; L=$1; SCOPE=$2; W=${3:-420}
ts() { echo "=== $(date -u +%T) $*"; }
ts "push archives";           $D push validators "$L" | sort | tail -1
ts "stop Platform";           $D node validators stop-platform | tail -1
if [ "$SCOPE" = platform+llmq ]; then
  ts "pause miner";           $D node wallet miner stop
  ts "stop Core";             $D node validators stop-core | tail -1
fi
ts "restore ($SCOPE)";        $D node validators restore "/var/tmp/dr/$L.tar.gz" "$SCOPE" | sort
if [ "$SCOPE" = platform+llmq ]; then
  ts "start Core";            $D node validators start-core | tail -1
  ts "wait for masternode sync on every Core (mining still paused)"
  for i in $(seq 1 40); do out=$($D watch 1); echo "$out" | sed 's/.*| core/core/'; echo "$out" | grep -q "synced=13" && break; sleep 5; done
  ts "resume miner";          $D node wallet miner start
fi
ts "start Platform";          $D node validators start-platform | tail -1
ts "watch";                   $D watch "$W" 30
ts "remove archives from nodes"; $D sh validators 'rm -rf /var/tmp/dr/*.tar.gz /tmp/dr-in' | tail -1
ts "done"
