#!/usr/bin/env python3
"""Controller for Platform backup and restore on a console devnet.

Written for the devnet disaster-recovery exercise (dashpay/infra #27); see ../README.md.
Runs on a machine that holds AWS credentials for the devnet's account and a copy of the
console's host-key pins ($DRILL_HOME/known_hosts). Reaches nodes with EC2 Instance Connect
(a throwaway key, pushed per connection) and runs dr-node.sh there as root.

  drill.py hosts
  drill.py node <targets> <dr-node.sh args...>      run dr-node.sh on targets in parallel
  drill.py sh <targets> '<shell>'                   run a root shell command on targets
  drill.py pull <targets> <label>                   fetch /var/tmp/dr/<label>.tar.gz and manifest, remove them on the node
  drill.py push <targets> <label>                   copy archives back to /var/tmp/dr/ on the nodes
  drill.py watch <seconds> [interval]               one summary line per poll of the validators
  drill.py revive <node>                            revive a PoSe-banned validator with one ProUpServTx
  drill.py state <name>                             save a fleet snapshot (info + blocks) as state/<name>.json and print a summary

<targets>: all | validators | wallet | a comma list of node names (validators-003,validators-007)
Environment: DRILL_NET (the devnet, for example devnet-drill), DRILL_HOME (default ~/dr),
AWS credentials and profile as boto3 finds them, AWS_REGION (default us-west-2).
"""
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import tempfile
import time

import boto3

NET = os.environ.get("DRILL_NET") or sys.exit("set DRILL_NET to the devnet's name, for example devnet-drill")
HOME = os.path.expanduser(os.environ.get("DRILL_HOME", "~/dr"))
REGION = os.environ.get("AWS_REGION", "us-west-2")
session = boto3.Session(region_name=REGION)
ACCOUNT = session.client("sts").get_caller_identity()["Account"]
ec2 = session.client("ec2")
KNOWN_HOSTS = os.path.join(HOME, "known_hosts")
NODE_SCRIPT = os.path.join(HOME, "tools", "dr-node.sh")
ARCHIVES = os.path.join(HOME, "archives")


def hosts():
    out = []
    pages = ec2.get_paginator("describe_instances").paginate(Filters=[
        {"Name": "tag:dashnet:network", "Values": [NET]}, {"Name": "instance-state-name", "Values": ["running"]}])
    for page in pages:
        for r in page["Reservations"]:
            for i in r["Instances"]:
                t = {x["Key"]: x["Value"] for x in i.get("Tags", [])}
                out.append({"name": t.get("dashnet:node") or t["Name"].replace(NET + "-", ""), "id": i["InstanceId"],
                            "ip": i.get("PublicIpAddress"), "role": t.get("dashnet:role"), "az": i["Placement"]["AvailabilityZone"]})
    return sorted(out, key=lambda h: h["name"])


def select(spec, all_hosts):
    if spec == "all":
        return all_hosts
    if spec == "validators":
        return [h for h in all_hosts if h["name"].startswith("validators-")]
    if spec == "wallet":
        return [h for h in all_hosts if h["name"].startswith("wallet-")]
    names = spec.split(",")
    chosen = [h for h in all_hosts if h["name"] in names]
    if len(chosen) != len(names):
        sys.exit("unknown target in %s" % spec)
    return chosen


class Key:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="dr-key-")
        self.path = os.path.join(self.dir, "k")
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "dr", "-f", self.path], check=True)
        self.pub = open(self.path + ".pub").read()
        self.eic = session.client("ec2-instance-connect")

    def opts(self, h):
        self.eic.send_ssh_public_key(InstanceId=h["id"], InstanceOSUser="ubuntu", SSHPublicKey=self.pub)
        return ["-i", self.path, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=" + KNOWN_HOSTS, "-o", "HostKeyAlias=%s.%s.%s.dashnet" % (h["id"], REGION, ACCOUNT),
                "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "LogLevel=ERROR"]

    def close(self):
        subprocess.run(["rm", "-rf", self.dir])


def ssh(key, h, command, stdin=None, timeout=900):
    r = subprocess.run(["ssh"] + key.opts(h) + ["ubuntu@" + h["ip"], command], input=stdin, capture_output=True, timeout=timeout)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def scp(key, h, src, dst, timeout=900):
    r = subprocess.run(["scp", "-q"] + key.opts(h) + [src, dst], capture_output=True, timeout=timeout)
    return r.returncode, "", r.stderr.decode("utf-8", "replace")


def fan(targets, fn):
    with cf.ThreadPoolExecutor(max_workers=16) as pool:
        return dict(zip([h["name"] for h in targets], pool.map(fn, targets)))


def node(key, targets, args, timeout=900):
    script = open(NODE_SCRIPT, "rb").read()
    quoted = " ".join("'%s'" % a.replace("'", "'\\''") for a in args)
    return fan(targets, lambda h: ssh(key, h, "sudo bash -s -- " + quoted, stdin=script, timeout=timeout))


def show(results):
    bad = 0
    for name, (rc, out, err) in results.items():
        tag = "" if rc == 0 else "  [rc %d]" % rc
        bad += rc != 0
        for line in (out.strip().splitlines() or [""]):
            print("%-15s %s%s" % (name, line, tag))
        if rc != 0 and err.strip():
            print("%-15s STDERR %s" % (name, err.strip()[-600:]))
    return bad


def kv(text):
    d = {}
    for line in text.splitlines():
        if line.startswith("c_"):
            parts = line.split(" ")
            head, val = parts[0].split("=", 1)
            d[head] = val
            for p in parts[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    d[head + "_" + k] = v
        elif line.startswith("du_"):
            for p in line.split(" "):
                if "=" in p:
                    k, v = p.split("=", 1)
                    d[k] = v
        elif "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def state(key, all_hosts, name):
    vals = select("validators", all_hosts)
    infos = {n: kv(out) for n, (rc, out, err) in node(key, vals, ["info"]).items()}
    heights = sorted(int(i["td_height"]) for i in infos.values() if i.get("td_height", "").isdigit())
    blocks = {}
    if heights:
        low = heights[0]
        for h in sorted({1, max(1, low - 1), low}):
            res = node(key, vals, ["block", str(h)])
            blocks[str(h)] = {n: out.split() for n, (rc, out, err) in res.items()}
    snap = {"name": name, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "info": infos, "blocks": blocks}
    os.makedirs(os.path.join(HOME, "state"), exist_ok=True)
    json.dump(snap, open(os.path.join(HOME, "state", name + ".json"), "w"), indent=1)
    print("state %s at %s" % (name, snap["at"]))
    for n, i in infos.items():
        print("%-15s td=%s catching_up=%s peers=%s q=%s app=%s core=%s cl=%s mn=%s  td:%s/%s drive:%s/%s core:%s/%s" % (
            n, i.get("td_height", "-"), i.get("td_catching_up", "-"), i.get("td_peers", "-"), i.get("td_quorum", "-")[:8], i.get("td_app_hash", "-")[:12],
            i.get("core_height", "-"), i.get("core_chainlock", "-"), i.get("mn_state", "-"),
            i.get("c_drive_tenderdash", "-"), i.get("c_drive_tenderdash_restarts", "-"), i.get("c_drive_abci", "-"), i.get("c_drive_abci_restarts", "-"),
            i.get("c_core", "-"), i.get("c_core_restarts", "-")))
    for h, per in blocks.items():
        distinct = {tuple(v[1:]) for v in per.values()}
        print("height %s: %d distinct (block hash, app hash) across %d nodes: %s" % (h, len(distinct), len(per), sorted(x[0][:16] + "/" + x[1][:16] for x in distinct if len(x) == 2)))
    return snap


def watch(key, all_hosts, seconds, interval):
    """One line per poll: enough to time recovery and to see a stall or a restart loop."""
    vals = select("validators", all_hosts)
    end = time.time() + seconds
    while True:
        t0 = time.time()
        infos = [kv(out) for rc, out, err in node(key, vals, ["info"]).values()]
        td = sorted(int(i["td_height"]) for i in infos if i.get("td_height", "").isdigit())
        core = sorted(int(i["core_height"]) for i in infos if i.get("core_height", "").isdigit())
        cl = sorted(int(i["core_chainlock"]) for i in infos if i.get("core_chainlock", "").isdigit())
        tip_hashes = {i.get("td_app_hash") for i in infos if i.get("td_height") == str(td[-1])} if td else set()
        print("%s td=%s reporting=%d/13 at_tip=%d catching_up=%d app_hashes_at_tip=%d quorum=%s peers_min=%s | containers td %s drive %s | restarts td=%d drive=%d | core=%s chainlock=%s ready=%d synced=%d core_peers_min=%s" % (
            time.strftime("%H:%M:%S", time.gmtime()), "%d..%d" % (td[0], td[-1]) if td else "-", len(td),
            sum(1 for h in td if h == td[-1]) if td else 0, sum(1 for i in infos if i.get("td_catching_up") == "True"), len(tip_hashes),
            ",".join(sorted({i.get("td_quorum", "-")[:8] for i in infos})), min([int(i["td_peers"]) for i in infos if i.get("td_peers", "").isdigit()] or [-1]),
            ",".join("%s:%d" % (k, v) for k, v in sorted(count(i.get("c_drive_tenderdash") for i in infos).items())),
            ",".join("%s:%d" % (k, v) for k, v in sorted(count(i.get("c_drive_abci") for i in infos).items())),
            sum(int(i.get("c_drive_tenderdash_restarts", 0) or 0) for i in infos), sum(int(i.get("c_drive_abci_restarts", 0) or 0) for i in infos),
            "%d..%d" % (core[0], core[-1]) if core else "-", "%d..%d" % (cl[0], cl[-1]) if cl else "-", sum(1 for i in infos if i.get("mn_state") == "READY"), sum(1 for i in infos if i.get("core_synced") == "true"),
            min([int(i["core_peers"]) for i in infos if i.get("core_peers", "").isdigit()] or [-1])), flush=True)
        if time.time() >= end:
            return
        time.sleep(max(0, interval - (time.time() - t0)))


def revive(key, all_hosts, name):
    """Revive a PoSe-banned validator: one ProUpServTx from the devnet wallet, as the console does it
    during creation. The operator key goes from the node to the wallet node's dash-cli -stdin; it is
    never printed, logged or put on a command line."""
    h = select(name, all_hosts)[0]
    w = select("wallet", all_hosts)[0]
    core = "docker exec -i $(docker ps --format '{{.Names}}' | grep -- '-core$' | head -1) dash-cli -conf=/etc/dash/dash.conf"
    rc, out, err = ssh(key, w, "sudo bash -s", stdin=("%s protx list registered true < /dev/null" % core).encode())
    mn = [m for m in json.loads(out) if str(m["state"].get("service", "")).startswith(h["ip"] + ":")][0]
    st = mn["state"]
    print("%s proTx %s penalty %s banHeight %s" % (name, mn["proTxHash"][:16], st["PoSePenalty"], st["PoSeBanHeight"]))
    if st["PoSeBanHeight"] <= 0:
        return print("not banned; nothing sent")
    rc, out, err = ssh(key, w, "sudo bash -s", stdin=("%s -rpcwallet=dashnet listlockunspent < /dev/null; echo ===; %s -rpcwallet=dashnet listunspent 1 9999999 '[]' true '{\"minimumAmount\":1,\"maximumAmount\":900,\"maximumCount\":40}' < /dev/null" % (core, core)).encode())
    locked, unspent = [json.loads(x) for x in out.split("===")]
    locked = {(u["txid"], u["vout"]) for u in locked}
    fee = [u for u in unspent if u["amount"] >= 1 and (u["txid"], u["vout"]) not in locked and u.get("address")][0]["address"]
    rc, secret, err = ssh(key, h, "sudo python3 -c 'import json;print(json.load(open(\"/var/lib/dashnet/secrets.json\"))[\"operatorPrivateKey\"])'")
    secret = secret.strip()
    if rc or len(secret) != 64:
        sys.exit("could not read the operator key on %s" % name)
    nl = chr(10)
    body = nl.join([secret, str(st["platformNodeID"]), str(st["platformP2PPort"]), str(st["platformHTTPPort"]), "", fee]) + nl
    script = "%s -rpcwallet=dashnet -stdin protx update_service_evo %s %s <<'DRILL_EOF'%s%sDRILL_EOF%s" % (core, mn["proTxHash"], st["service"], nl, body, nl)
    rc, out, err = ssh(key, w, "sudo bash -s", stdin=script.encode())
    print("ProUpServTx %s rc %d %s" % (out.strip(), rc, err.strip()[-300:].replace(secret, "<redacted>")))


def count(items):
    out = {}
    for x in items:
        out[str(x)] = out.get(str(x), 0) + 1
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, all_hosts = sys.argv[1], hosts()
    if cmd == "hosts":
        for h in all_hosts:
            print(h["name"], h["id"], h["ip"], h["role"], h["az"])
        return
    key = Key()
    try:
        if cmd == "state":
            state(key, all_hosts, sys.argv[2])
            return
        if cmd == "revive":
            revive(key, all_hosts, sys.argv[2])
            return
        if cmd == "watch":
            watch(key, all_hosts, int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 30)
            return
        targets = select(sys.argv[2], all_hosts)
        if cmd == "node":
            sys.exit(1 if show(node(key, targets, sys.argv[3:])) else 0)
        if cmd == "sh":
            sys.exit(1 if show(fan(targets, lambda h: ssh(key, h, "sudo bash -s", stdin=sys.argv[3].encode()))) else 0)
        label = sys.argv[3]
        os.makedirs(ARCHIVES, mode=0o700, exist_ok=True)
        if cmd == "pull":
            def pull(h):
                base = "/var/tmp/dr/" + label
                local = os.path.join(ARCHIVES, "%s.%s" % (label, h["name"]))
                rc, out, err = ssh(key, h, "sudo chown ubuntu %s.tar.gz %s.manifest && sudo chmod 711 /var/tmp/dr" % (base, base))
                if rc:
                    return rc, out, err
                for ext in (".tar.gz", ".manifest"):
                    rc, out, err = scp(key, h, "ubuntu@%s:%s%s" % (h["ip"], base, ext), local + ext)
                    if rc:
                        return rc, out, err
                digest = subprocess.run(["sha256sum", local + ".tar.gz"], capture_output=True, text=True).stdout.split()[0]
                want = [l.split("=", 1)[1] for l in open(local + ".manifest").read().splitlines() if l.startswith("sha256=")][0]
                if digest != want:
                    return 1, "", "checksum mismatch"
                rc, out, err = ssh(key, h, "sudo rm -f %s.tar.gz %s.manifest %s.tar.err" % (base, base, base))
                return rc, "pulled %d bytes sha256 %s" % (os.path.getsize(local + ".tar.gz"), digest[:16]), err
            sys.exit(1 if show(fan(targets, pull)) else 0)
        if cmd == "push":
            def push(h):
                local = os.path.join(ARCHIVES, "%s.%s.tar.gz" % (label, h["name"]))
                rc, out, err = ssh(key, h, "sudo install -d -m 700 /var/tmp/dr && install -d -m 700 /tmp/dr-in")
                if rc:
                    return rc, out, err
                rc, out, err = scp(key, h, local, "ubuntu@%s:/tmp/dr-in/%s.tar.gz" % (h["ip"], label))
                if rc:
                    return rc, out, err
                return ssh(key, h, "sudo mv /tmp/dr-in/%s.tar.gz /var/tmp/dr/ && sudo chown root:root /var/tmp/dr/%s.tar.gz && sudo sha256sum /var/tmp/dr/%s.tar.gz | cut -c1-16" % (label, label, label))
            sys.exit(1 if show(fan(targets, push)) else 0)
        sys.exit(__doc__)
    finally:
        key.close()


if __name__ == "__main__":
    main()
