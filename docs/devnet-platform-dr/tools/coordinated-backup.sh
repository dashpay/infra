#!/usr/bin/env bash
# usage: coordinated-backup.sh <label>   -- fleet-wide cold backup in one window
set -uo pipefail
cd "${DRILL_HOME:-$HOME/dr}"; D="python3 tools/drill.py"; L=$1
ts() { echo "=== $(date -u +%T) $*"; }
ts "pause miner";            $D node wallet miner stop
ts "quiesce Platform";       $D node validators quiesce | sort
ts "stop Core";              $D node validators stop-core | sort | tail -1
ts "archive";                $D node validators backup cold "$L" | grep -E "tar_rc|bytes=|finished=" | sort
ts "start Core";             $D node validators start-core | tail -1
# On a devnet with 10 s blocks, masternode sync after a fleet-wide Core restart does not
# finish while blocks keep arriving, so mining stays paused until every Core reports synced.
ts "wait for masternode sync on every Core (mining still paused)"
for i in $(seq 1 40); do out=$($D watch 1); echo "$out" | sed 's/.*| core/core/'; echo "$out" | grep -q "synced=13" && break; sleep 5; done
ts "resume miner";           $D node wallet miner start
ts "start Platform";         $D node validators start-platform | tail -1
ts "pull archives";          $D pull validators "$L" | sort
ts "done"; ls -la archives | grep "$L" | awk '{s+=$5} END {print NR" files, "s" bytes"}'
