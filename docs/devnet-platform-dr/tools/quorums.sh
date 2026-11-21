#!/usr/bin/env bash
# Platform quorums as one validator's Core sees them: height, age in blocks, valid members.
C=$(docker ps --format '{{.Names}}' | grep -E -- '-core$' | head -1)
python3 - "$C" <<'PY'
import subprocess, json, sys
C = sys.argv[1]
def cli(*a): return json.loads(subprocess.check_output(["docker", "exec", C, "dash-cli", *a]))
tip = cli("getblockcount")
out = []
for q in cli("quorum", "list")["llmq_devnet_platform"]:
    i = cli("quorum", "info", "107", q)
    out.append("%s@%d(age %d, %d/%d valid)" % (q[:8], i["height"], tip - i["height"], sum(1 for m in i["members"] if m.get("valid")), len(i["members"])))
print("core tip %d platform quorums: %s" % (tip, " ".join(out)))
PY
