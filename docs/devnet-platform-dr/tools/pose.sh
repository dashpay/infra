#!/usr/bin/env bash
# PoSe state of every masternode as this node's Core sees it, plus recent punishments from its log.
C=$(docker ps --format '{{.Names}}' | grep -E -- '-core$' | head -1)
python3 - "$C" <<'PY'
import subprocess, json, sys
C = sys.argv[1]
def cli(*a): return json.loads(subprocess.check_output(["docker", "exec", C, "dash-cli", *a]))
tip = cli("getblockcount")
print("core tip", tip)
for m in sorted(cli("protx", "list", "registered", "true"), key=lambda m: str(m["state"].get("service") or m["state"].get("addresses"))):
    s = m["state"]
    print(m["proTxHash"][:12], str(s.get("service") or s.get("addresses"))[:40], "penalty", s["PoSePenalty"], "banHeight", s["PoSeBanHeight"], "revived", s["PoSeRevivedHeight"])
PY
docker logs "$C" 2>&1 | grep -E "PoSePunish|PoSeBan" | tail -12 | cut -c1-200
