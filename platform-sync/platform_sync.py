#!/usr/bin/env python3
"""platform-sync: replay Dash Platform from genesis on one host, every night.

One daemon per network. It waits for a request file, wipes the Platform state
of its stack (Core is kept), starts Drive and Tenderdash with the requested
Drive image and watches the replay until the node is at the network's tip or
has failed. Between runs it keeps publishing where the node is.

Python standard library only.
The operating guide is README.md in this directory.
"""
import argparse
import collections
import datetime as dt
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULTS = {
    "root": "/srv/platform-sync",
    "tick_seconds": 30,
    "limits": {
        "min_free_gib_start": 15,   # refuse to start a replay below this
        "min_free_gib_abort": 5,    # stop a running replay below this
        "min_free_state_gib": 0.5,  # same, for the memory filesystem that holds the Platform state
        "timeout_hours": 20,
        "stall_minutes": 30,        # no new block for this long while behind
        "max_restarts": 5,          # of Drive or Tenderdash during one replay
        "tip_blocks": 3,            # blocks to follow at the tip before passing
        "tip_lag_blocks": 2,
        "core_wait_minutes": 3,     # for a Core that was just restarted, not for a first sync
    },
    # What "auto" means: the newest published tag of the Drive image that looks
    # like a release, prereleases included. The images Platform CI builds for
    # each commit cannot be used: they are dev-profile builds that write SDK
    # test data into the genesis state, so they never match a real network.
    "auto": {
        "image": "dashpay/drive",
        "tag_pattern": r"^\d+\.\d+\.\d+(-(dev|alpha|beta|rc)\.\d+)?$",
        # Tenderdash is taken from dashmate's defaults at the same release tag.
        "source": "https://raw.githubusercontent.com/dashpay/platform/v{tag}"
                  "/packages/dashmate/configs/defaults/getBaseConfigFactory.js",
    },
    # The status console shows one tile per network. Nothing is sent while the token file is absent.
    "report": {
        "url": "https://status.testnet.networks.dash.org/api/platform-sync/report",
        "token_file": "/etc/platform-sync/report-token",
        "every_seconds": 120,
    },
    "networks": {
        "testnet": {
            "td_rpc": "http://127.0.0.1:36657",
            "td_metrics": "http://127.0.0.1:36660/metrics",
            "reference": {"type": "status-api",
                          "url": "https://status.testnet.networks.dash.org/api/nodes"},
        },
        "mainnet": {
            "td_rpc": "http://127.0.0.1:46657",
            "td_metrics": "http://127.0.0.1:46660/metrics",
            "reference": {"type": "tenderdash-rpc", "url": "http://127.0.0.1:26657"},
        },
    },
}

# What a request may ask for. Anything else is refused before Docker sees it.
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
IMAGE_RE = re.compile(
    r"^(?:dashpay/(?:drive|tenderdash)|ghcr\.io/dashpay/[a-z0-9._/-]{1,80})"
    r"(?::[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[0-9a-f]{64})$")
FATAL_LOG = [
    (re.compile(r"wrong Block\.Header\.AppHash"), "AppHash mismatch"),
    (re.compile(r"CONSENSUS FAILURE"), "Tenderdash consensus failure"),
]
PLATFORM_SERVICES = ("drive_abci", "drive_tenderdash")
RUNNING = ("starting", "syncing", "verifying")


def now():
    return dt.datetime.now(dt.timezone.utc)


def iso(t=None):
    return (t or now()).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def log(*a):
    print(iso(), *a, flush=True)


def merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_config(path):
    over = {}
    if path and os.path.exists(path):
        with open(path) as f:
            over = json.load(f)
    return merge(DEFAULTS, over)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj, mode=0o600):
    tmp = f"{path}.tmp{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def parse_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    return env


def http(url, headers=None, timeout=15, method="GET"):
    req = urllib.request.Request(url, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, dict(r.headers), r.read()


def http_json(url, headers=None, timeout=15):
    return json.loads(http(url, headers, timeout)[2])


def sh(cmd, check=True, timeout=600, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:4])}… exited {r.returncode}: {(r.stderr or r.stdout).strip()[-400:]}")
    return r


def validate_request(req, network):
    """Returns the cleaned request or raises ValueError. Pure: easy to test."""
    if not isinstance(req, dict):
        raise ValueError("request is not an object")
    rid = req.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise ValueError("bad id")
    if req.get("network") != network:
        raise ValueError("wrong network")
    out = {"id": rid, "network": network, "force": req.get("force") is True}
    for key in ("image", "tenderdash_image"):
        v = req.get(key, "auto" if key == "image" else None)
        if v in (None, "", "auto"):
            out[key] = "auto" if key == "image" else None
            continue
        if not isinstance(v, str) or not IMAGE_RE.match(v):
            raise ValueError(f"{key} is not an allowed image reference")
        if (key == "tenderdash_image") != ("tenderdash" in v.split("/")[-1].split(":")[0].split("@")[0]):
            raise ValueError(f"{key} names the wrong repository")
        out[key] = v
    return out


def sum_p2p_bytes(metrics_text):
    """(received, sent) message bytes summed over peers from a Prometheus metrics page.

    Series with an empty peer_id are left out: Tenderdash 2.0.0-dev.3 books every
    received message a second time there as "sent" (to its own reactor). These are
    message sizes, not bytes on the wire; see internet_counters for the latter.
    """
    rx = tx = 0.0
    for line in metrics_text.splitlines():
        if line.startswith("#") or " " not in line or 'peer_id=""' in line:
            continue
        name, value = line.rsplit(" ", 1)
        name = name.split("{", 1)[0]
        try:
            if name.endswith("p2p_peer_receive_bytes_total"):
                rx += float(value)
            elif name.endswith("p2p_peer_send_bytes_total"):
                tx += float(value)
        except ValueError:
            pass
    return int(rx), int(tx)


# Docker's private range on this host. Traffic that stays inside it (other containers,
# the mainnet observer) is not internet traffic.
LOCAL_RANGE = "172.16.0.0/12"


def counting_rules(subnet, tag):
    """The two rules without a target that count a stack's internet traffic."""
    return {"internetTx": ["-s", subnet, "!", "-d", LOCAL_RANGE, "-m", "comment", "--comment", f"{tag}-out"],
            "internetRx": ["-d", subnet, "!", "-s", LOCAL_RANGE, "-m", "comment", "--comment", f"{tag}-in"]}


def parse_rule_bytes(listing, tag):
    """Byte counters of the counting rules, from `iptables -v -S DOCKER-USER`."""
    out = {}
    for line in listing.splitlines():
        which = re.search(r'--comment "?%s-(in|out)"?(\s|$)' % re.escape(tag), line)
        count = re.search(r"\s-c \d+ (\d+)(\s|$)", line)
        if which and count:
            out["internetRx" if which.group(1) == "in" else "internetTx"] = int(count.group(1))
    return out


def rate(samples, window=600):
    """Blocks a second over the last `window` seconds of (time, height) samples."""
    if len(samples) < 2:
        return None
    t1, h1 = samples[-1]
    old = [s for s in samples if t1 - s[0] <= window]
    t0, h0 = old[0]
    return (h1 - h0) / (t1 - t0) if t1 > t0 and h1 >= h0 else None


class Registry:
    """Just enough of the registry API to ask whether a tag exists and how big it is."""
    ACCEPT = ("application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, "
              "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json")

    def __init__(self, image):
        self.host, self.repo = image.split("/", 1) if "." in image.split("/")[0] else ("registry-1.docker.io", image)
        self._token = None

    def _headers(self):
        if self._token is None:
            realm = ("https://ghcr.io/token?service=ghcr.io" if self.host == "ghcr.io"
                     else "https://auth.docker.io/token?service=registry.docker.io")
            self._token = http_json(f"{realm}&scope=repository:{self.repo}:pull")["token"]
        return {"Authorization": f"Bearer {self._token}", "Accept": self.ACCEPT}

    def manifest(self, ref):
        try:
            return json.loads(http(f"https://{self.host}/v2/{self.repo}/manifests/{ref}", self._headers())[2])
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 404):
                return None
            raise

    def compressed_size(self, ref, arch="amd64"):
        m = self.manifest(ref)
        if m and "manifests" in m:
            pick = [x for x in m["manifests"] if x.get("platform", {}).get("architecture") == arch]
            m = self.manifest(pick[0]["digest"]) if pick else None
        if not m:
            return None
        return sum(l.get("size", 0) for l in m.get("layers", [])) + m.get("config", {}).get("size", 0)


class Sync:
    def __init__(self, cfg, network):
        self.cfg, self.net = cfg, network
        self.n = cfg["networks"][network]
        self.lim = cfg["limits"]
        self.root = cfg["root"]
        self.env_file = f"{self.root}/state/{network}.env"
        self.sync_env_file = f"{self.root}/state/{network}.sync.env"
        self.state_file = f"{self.root}/state/{network}.json"
        self.requests = f"{self.root}/spool/requests"
        self.status_dir = f"{self.root}/spool/status"
        self.project = parse_env(self.env_file)["COMPOSE_PROJECT_NAME"]
        self.hold_file = f"{self.root}/state/{network}.hold"
        # Drive and Tenderdash state lives in memory (a tmpfs of fixed size): a replay
        # syncs to disk several times per block, and this host's disk takes 8 to 30 ms
        # for each. The state is rebuilt by every run, so nothing of value is at risk.
        self.pdata = f"{self.root}/ram/{network}"
        self.state = read_json(self.state_file) or {"phase": "idle", "run": None, "last_passed": None,
                                                     "last_request": None, "pulled": []}
        self.samples = collections.deque(maxlen=400)
        self.last_counters = None
        self.reported = (0, None, None)  # when, which phase, last error

    def hold(self):
        """A hold keeps the next run from wiping a failed node somebody is looking at."""
        try:
            with open(self.hold_file) as f:
                return f.read().strip() or "no reason given"
        except OSError:
            return None

    # ---- docker ---------------------------------------------------------
    def container(self, service):
        return f"{self.project}-{service}-1"

    def compose(self, *args, timeout=900, check=True):
        env = dict(os.environ)
        env.update(parse_env(self.env_file))
        env.update(parse_env(self.sync_env_file))
        env["COMPOSE_FILE"] = (env["COMPOSE_FILE"] + env.get("COMPOSE_PATH_SEPARATOR", ":")
                               + f"{self.root}/compose.override.yml")
        return sh(["docker", "compose", *args], env=env, cwd=f"{self.root}/dashmate", timeout=timeout, check=check)

    def set_sync_env(self, **kv):
        env = parse_env(self.sync_env_file)
        for k, v in kv.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        tmp = self.sync_env_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("".join(f"{k}={v}\n" for k, v in env.items()))
        os.replace(tmp, self.sync_env_file)

    def inspect(self, service):
        r = sh(["docker", "inspect", self.container(service)], check=False)
        if r.returncode != 0:
            return None
        c = json.loads(r.stdout)[0]
        s = c["State"]
        return {"status": s["Status"], "restarts": c["RestartCount"], "oom": s.get("OOMKilled", False),
                "started": s.get("StartedAt"), "image": c["Config"]["Image"], "image_id": c["Image"],
                "exit": s.get("ExitCode")}

    def core_cli(self, *args):
        r = sh(["docker", "exec", self.container("core"), "dash-cli", *args], check=False, timeout=60)
        if r.returncode != 0:
            return None
        try:
            return json.loads(r.stdout)
        except ValueError:
            return r.stdout.strip()

    def core_ready(self):
        info = self.core_cli("getblockchaininfo")
        mn = self.core_cli("mnsync", "status")
        if not isinstance(info, dict) or not isinstance(mn, dict):
            return False, "Core does not answer"
        if info.get("initialblockdownload") or info.get("blocks") != info.get("headers"):
            return False, f"Core is still syncing ({info.get('blocks')}/{info.get('headers')})"
        if not mn.get("IsSynced"):
            return False, f"Core masternode sync not finished ({mn.get('AssetName')})"
        return True, info.get("blocks")

    # ---- observation ----------------------------------------------------
    def td_status(self, base=None):
        try:
            r = http_json((base or self.n["td_rpc"]) + "/status", timeout=8)
        except (OSError, ValueError):
            return None
        r = r.get("result", r)
        s = r.get("sync_info", {})
        return {"height": int(s.get("latest_block_height") or 0), "catching_up": s.get("catching_up"),
                "time": s.get("latest_block_time"), "version": r.get("node_info", {}).get("version")}

    def td_block(self, base, height):
        r = http_json(f"{base}/block?height={height}", timeout=10)
        r = r.get("result", r)
        return r["block_id"]["hash"].upper(), r["block"]["header"]["app_hash"].upper()

    def reference_height(self):
        ref = self.n["reference"]
        try:
            if ref["type"] == "tenderdash-rpc":
                s = self.td_status(ref["url"])
                return s["height"] if s else None
            nodes = http_json(ref["url"], timeout=20)
            hs = [n["status"].get("platformBlockHeight") for n in nodes
                  if isinstance(n.get("status"), dict) and n["status"].get("platformStatus") == "up"]
            return max(h for h in hs if isinstance(h, int)) if hs else None
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def disk(self):
        u = shutil.disk_usage(self.root)
        g = 2 ** 30
        out = {"sizeGiB": round(u.total / g, 1), "usedGiB": round(u.used / g, 1), "freeGiB": round(u.free / g, 1)}
        if os.path.ismount(self.pdata):
            m = shutil.disk_usage(self.pdata)
            out.update(stateSizeGiB=round(m.total / g, 1), stateUsedGiB=round(m.used / g, 2),
                       stateFreeGiB=round(m.free / g, 2))
        return out

    def internet_counters(self):
        """Bytes the whole stack exchanged with the internet, counted by the kernel.

        Two rules in Docker's DOCKER-USER chain count what is forwarded between the
        stack's subnet and anything outside Docker's private range. They are appended,
        so on mainnet they sit behind the REJECT rule and stay at zero. The rules are
        put back when missing (a reboot or a firewall reload empties the chain).
        """
        subnet = parse_env(self.env_file).get("DOCKER_NETWORK_SUBNET")
        if not subnet:
            return {}
        tag = f"platform-sync-{self.net}"
        for rule in counting_rules(subnet, tag).values():
            if sh(["iptables", "-w", "5", "-C", "DOCKER-USER", *rule], check=False, timeout=30).returncode != 0:
                sh(["iptables", "-w", "5", "-A", "DOCKER-USER", *rule], check=False, timeout=30)
        r = sh(["iptables", "-w", "5", "-v", "-S", "DOCKER-USER"], check=False, timeout=30)
        return parse_rule_bytes(r.stdout or "", tag) if r.returncode == 0 else {}

    def counters(self):
        """Cumulative bytes: the stack's internet traffic from the firewall counters,
        Tenderdash p2p messages from its metrics, Core p2p from getnettotals."""
        out = {}
        try:
            out.update(self.internet_counters())
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            out["platformRx"], out["platformTx"] = sum_p2p_bytes(
                http(self.n["td_metrics"], timeout=8)[2].decode("utf-8", "replace"))
        except (OSError, ValueError):
            pass
        t = self.core_cli("getnettotals")
        if isinstance(t, dict):
            out["coreRx"], out["coreTx"] = t.get("totalbytesrecv", 0), t.get("totalbytessent", 0)
        return out

    def add_bytes(self, b):
        """Counters restart from zero with their container, so add up the increases."""
        cur = self.counters()
        prev = self.last_counters or {}
        for k, v in cur.items():
            if k in prev:
                b[k] = b.get(k, 0) + (v - prev[k] if v >= prev[k] else v)
            else:
                b.setdefault(k, 0)
        # A counter that could not be read this time keeps its last value as the baseline.
        self.last_counters = {**prev, **cur}

    def scan_logs(self, since):
        for service in PLATFORM_SERVICES:
            r = sh(["docker", "logs", "--since", since, self.container(service)], check=False, timeout=60)
            text = (r.stdout or "") + (r.stderr or "")
            for rx, label in FATAL_LOG:
                m = rx.search(text)
                if m:
                    line = text[text.rfind("\n", 0, m.start()) + 1:text.find("\n", m.end())]
                    return f"{label}: {line.strip()[:400]}"
        return None

    # ---- image resolution -----------------------------------------------
    def resolve_auto(self):
        """The newest release tag of Drive, and the Tenderdash that release ships with."""
        a = self.cfg["auto"]
        tags = http_json(f"https://hub.docker.com/v2/repositories/{a['image']}/tags?page_size=100&ordering=last_updated")
        tag = next((t["name"] for t in tags["results"] if re.match(a["tag_pattern"], t["name"])), None)
        if not tag:
            raise RuntimeError(f"no tag of {a['image']} matches {a['tag_pattern']}")
        out = {"ref": f"{a['image']}:{tag}", "source": "release", "tag": tag, "notes": [],
               "compressedBytes": Registry(a["image"]).compressed_size(tag), "tenderdash": None}
        try:
            js = http(a["source"].format(tag=tag))[2].decode("utf-8", "replace")
            m = re.search(r"image:\s*'(dashpay/tenderdash:[A-Za-z0-9._-]+)'", js)
            if m:
                out["tenderdash"] = m.group(1)
            else:
                out["notes"].append("no Tenderdash image found in dashmate's defaults for this tag")
        except OSError as e:
            out["notes"].append(f"dashmate defaults for v{tag} not readable ({e}); using the installed default")
        return out

    def pull(self, image):
        """Pulls unless present. Returns (image id, labels, True if it was downloaded)."""
        def look():
            r = sh(["docker", "image", "inspect", image], check=False)
            return json.loads(r.stdout)[0] if r.returncode == 0 else None
        before = look()
        # A tag can move (5-dev), a digest or commit tag cannot.
        if before is None or "@sha256:" not in image:
            sh(["docker", "pull", "--quiet", image], timeout=1800)
        after = look()
        if after is None:
            raise RuntimeError(f"{image} is not present after pull")
        return after["Id"], after["Config"].get("Labels") or {}, before is None or before["Id"] != after["Id"]

    def prune_images(self):
        used = set()
        for line in sh(["docker", "ps", "-a", "--no-trunc", "--format", "{{.Image}} {{.ID}}"]).stdout.split("\n"):
            if line.strip():
                r = sh(["docker", "inspect", "-f", "{{.Image}}", line.split()[1]], check=False)
                used.add(r.stdout.strip())
        keep = []
        for image_id in self.state.get("pulled", []):
            if image_id in used:
                keep.append(image_id)
            elif sh(["docker", "image", "inspect", image_id], check=False).returncode == 0:
                r = sh(["docker", "rmi", "--force", image_id], check=False)
                log("removed image" if r.returncode == 0 else "could not remove image", image_id[:19])
                if r.returncode != 0:
                    keep.append(image_id)
        self.state["pulled"] = keep

    # ---- a run ----------------------------------------------------------
    def next_request(self):
        try:
            names = sorted(os.listdir(self.requests))
        except OSError:
            return None
        for name in names:
            path = os.path.join(self.requests, name)
            if not name.endswith(".json"):
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as f:
                    st = os.fstat(f.fileno())
                    if not stat.S_ISREG(st.st_mode) or st.st_size > 4096:
                        raise ValueError("not a small regular file")
                    raw = json.loads(f.read(4097))
            except (OSError, ValueError) as e:
                log("dropping unreadable request", repr(name)[:80], e)
                self._unlink(path)
                continue
            if not isinstance(raw, dict) or raw.get("network") != self.net:
                continue  # the other network's daemon takes it; junk ages out below
            try:
                req = validate_request(raw, self.net)
            except ValueError as e:
                log("refusing request", repr(name)[:80], e)
                self._unlink(path)
                if isinstance(raw.get("id"), str) and ID_RE.match(raw["id"]):
                    self.write_result({"id": raw["id"], "network": self.net, "result": "refused", "reason": str(e),
                                       "finishedAt": iso()})
                continue
            self._unlink(path)
            return req
        return None

    def sweep_spool(self):
        """Requests nobody claimed and results older than a week."""
        for d, age in ((self.requests, 86400), (f"{self.status_dir}/results", 7 * 86400)):
            try:
                for name in os.listdir(d):
                    p = os.path.join(d, name)
                    if time.time() - os.lstat(p).st_mtime > age:
                        self._unlink(p)
            except OSError:
                pass

    @staticmethod
    def _unlink(path):
        try:
            os.unlink(path)
        except OSError:
            pass

    def write_result(self, run):
        os.makedirs(f"{self.status_dir}/results", exist_ok=True)
        write_json(f"{self.status_dir}/results/{run['id']}.json", run, 0o644)

    def record(self, run):
        self.state["last_request"] = {k: run.get(k) for k in ("id", "result", "reason", "finishedAt")}
        self.write_result(run)
        with open(f"{self.root}/state/history-{self.net}.jsonl", "a") as f:
            f.write(json.dumps(run, sort_keys=True) + "\n")

    def reject(self, run, result, reason):
        """Ends a request before anything on the node was touched. The node stays as it is."""
        run.update(result=result, reason=reason, finishedAt=iso())
        log(f"run {run['id']}: {result} ({reason})")
        self.record(run)

    def finish(self, result, reason=None):
        """Ends a replay that was started."""
        run = self.state["run"]
        run.update(result=result, reason=reason, finishedAt=iso())
        if run.get("startedAt"):
            run["durationSeconds"] = int((parse_iso(run["finishedAt"]) - parse_iso(run["startedAt"])).total_seconds())
        log(f"run {run['id']}: {result}" + (f" ({reason})" if reason else ""))
        if result == "failed":
            self.save_evidence(run)
            # Stop the Platform services and leave their data where it is,
            # so the failure can be looked at until the next run starts.
            self.compose("stop", *PLATFORM_SERVICES, check=False)
            self.state["phase"] = "failed"
        elif result == "passed":
            self.state["phase"] = "following"
            self.state["last_passed"] = {k: run.get(k) for k in
                                         ("id", "image", "finishedAt", "durationSeconds", "height", "bytes")}
            self.state["following"] = {"since": run["finishedAt"], "bytes": {}}
            self.state["following_healthy"] = True
        self.record(run)
        try:
            self.prune_images()
        except Exception as e:
            log("image cleanup failed:", e)

    def save_evidence(self, run):
        d = f"{self.root}/runs/{self.net}/{run['id']}"
        os.makedirs(d, exist_ok=True)
        for service in PLATFORM_SERVICES:
            r = sh(["docker", "logs", "--tail", "3000", self.container(service)], check=False, timeout=120)
            with open(f"{d}/{service}.log", "w") as f:
                f.write((r.stdout or "") + (r.stderr or ""))
        write_json(f"{d}/run.json", run)
        # Keep the evidence of the last ten runs that failed.
        base = f"{self.root}/runs/{self.net}"
        for old in sorted(os.listdir(base), key=lambda x: os.path.getmtime(os.path.join(base, x)))[:-10]:
            shutil.rmtree(os.path.join(base, old), ignore_errors=True)

    def start_run(self, req):
        run = {"id": req["id"], "network": self.net, "requestedImage": req["image"], "requestedAt": iso(),
               "result": None, "reason": None, "bytes": {}}
        log(f"run {run['id']}: requested image {req['image']}")
        if self.hold():
            return self.reject(run, "refused", f"on hold: {self.hold()}")
        for mount in (self.root, self.pdata):
            if not os.path.ismount(mount):
                return self.reject(run, "failed", f"{mount} is not mounted")
        free = self.disk()["freeGiB"]
        if free < self.lim["min_free_gib_start"]:
            return self.reject(run, "failed",
                               f"only {free} GiB free in {self.root}, need {self.lim['min_free_gib_start']}")
        if not self.inspect("core") or self.inspect("core")["status"] != "running":
            self.compose("up", "-d", "--no-deps", "core")
        deadline = time.time() + self.lim["core_wait_minutes"] * 60
        while True:
            ok, why = self.core_ready()
            if ok or time.time() > deadline:
                break
            time.sleep(20)
        if not ok:
            return self.reject(run, "failed", why)
        try:
            img = ({"ref": req["image"], "source": "request", "notes": []}
                   if req["image"] != "auto" else self.resolve_auto())
            image_id, labels, downloaded = self.pull(img["ref"])
            tenderdash = req.get("tenderdash_image") or img.get("tenderdash")
            if tenderdash:
                td_id, _, td_downloaded = self.pull(tenderdash)
                if td_downloaded and td_id not in self.state["pulled"]:
                    self.state["pulled"].append(td_id)
        except Exception as e:
            return self.reject(run, "failed", f"image: {str(e)[:300]}")
        if downloaded and image_id not in self.state["pulled"]:
            self.state["pulled"].append(image_id)
        run["image"] = {"ref": img["ref"], "id": image_id, "source": img["source"],
                        "revision": labels.get("org.opencontainers.image.revision"),
                        "version": labels.get("org.opencontainers.image.version") or img.get("tag"),
                        "notes": img.get("notes") or []}
        run["bytes"]["image"] = (img.get("compressedBytes") or 0) if downloaded else 0
        last = self.state.get("last_passed") or {}
        if (req["image"] == "auto" and not req["force"] and self.state["phase"] == "following"
                and self.state.get("following_healthy") and (last.get("image") or {}).get("id") == image_id):
            return self.reject(run, "skipped", "this image already passed and the node is still following the tip")
        # From here the old Platform state goes.
        self.state["run"] = run
        self.state["phase"] = "starting"
        self.state.pop("following", None)
        core_before = {k: v for k, v in self.counters().items() if k.startswith(("core", "internet"))}
        self.compose("rm", "--stop", "--force", *PLATFORM_SERVICES, check=False)
        sh(["docker", "volume", "rm", "--force", f"{self.project}_drive_abci_data",
            f"{self.project}_drive_tenderdash"], check=False)
        for d in ("drive", "tenderdash"):
            path = f"{self.pdata}/{d}"
            os.makedirs(path, exist_ok=True)
            for entry in os.listdir(path):
                p = os.path.join(path, entry)
                shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.unlink(p)
        self.set_sync_env(PLATFORM_DRIVE_ABCI_DOCKER_IMAGE=img["ref"],
                          PLATFORM_DRIVE_TENDERDASH_DOCKER_IMAGE=tenderdash)
        try:
            self.compose("up", "-d", "--no-deps", *PLATFORM_SERVICES)
        except Exception as e:
            return self.finish("failed", f"start: {str(e)[:300]}")
        run["startedAt"] = iso()
        run["tenderdashImage"] = (self.inspect("drive_tenderdash") or {}).get("image")
        self.samples.clear()
        # Fresh containers count from zero; Core and the firewall counters carry on.
        self.last_counters = {**core_before, "platformRx": 0, "platformTx": 0}
        self.state["phase"] = "syncing"
        self.state["progress_at"] = time.time()
        self.state["progress_height"] = 0
        self.state["log_scanned"] = run["startedAt"]

    def watch(self):
        """One look at a running replay. Decides pass or fail."""
        run = self.state["run"]
        age = (now() - parse_iso(run["startedAt"])).total_seconds()
        self.add_bytes(run["bytes"])
        states = {s: self.inspect(s) for s in PLATFORM_SERVICES}
        run["restarts"] = {s: (c or {}).get("restarts") for s, c in states.items()}
        scan_from, self.state["log_scanned"] = self.state.get("log_scanned") or run["startedAt"], iso()
        fatal = self.scan_logs(scan_from)
        if fatal:
            return self.finish("failed", fatal)
        for s, c in states.items():
            if c is None:
                return self.finish("failed", f"{s} container is gone")
            if c["oom"]:
                return self.finish("failed", f"{s} was killed for memory")
            if c["restarts"] >= self.lim["max_restarts"]:
                return self.finish("failed", f"{s} restarted {c['restarts']} times")
            if c["status"] not in ("running", "restarting"):
                return self.finish("failed", f"{s} is {c['status']} (exit {c['exit']})")
        disk = self.disk()
        if disk["freeGiB"] < self.lim["min_free_gib_abort"]:
            return self.finish("failed", f"stopped: only {disk['freeGiB']} GiB free in {self.root}")
        if disk.get("stateFreeGiB", 0) < self.lim["min_free_state_gib"]:
            return self.finish("failed", f"stopped: the Platform state has outgrown its {disk.get('stateSizeGiB')} GiB "
                                         f"memory filesystem; raise its size in /etc/fstab")
        if age > self.lim["timeout_hours"] * 3600:
            return self.finish("failed", f"not at the tip after {self.lim['timeout_hours']} hours")
        td = self.td_status()
        ref = self.reference_height()
        height = td["height"] if td else 0
        run.update(height=height, referenceHeight=ref, tenderdash=(td or {}).get("version") or run.get("tenderdash"))
        if height > self.state.get("progress_height", 0):
            self.state["progress_height"], self.state["progress_at"] = height, time.time()
        self.samples.append((time.time(), height))
        behind = ref is None or height < ref - self.lim["tip_lag_blocks"]
        if behind or not td or td["catching_up"]:
            self.state["phase"] = "syncing"
            run.pop("tipHeight", None)
            if time.time() - self.state["progress_at"] > self.lim["stall_minutes"] * 60:
                return self.finish("failed", f"no new block for {self.lim['stall_minutes']} minutes at height {height}"
                                             + ("" if ref else "; the reference height is not readable"))
            return
        # At the tip: follow it for a few blocks, then compare with the reference where there is one.
        self.state["phase"] = "verifying"
        run.setdefault("tipHeight", height)
        run.setdefault("tipReachedAt", iso())
        if height < run["tipHeight"] + self.lim["tip_blocks"]:
            # A quiet chain makes a block every few minutes; that is not a stall.
            if time.time() - self.state["progress_at"] > max(self.lim["stall_minutes"], 60) * 60:
                return self.finish("failed", f"reached the tip at {run['tipHeight']} and then stopped following")
            return
        refc = self.n["reference"]
        if refc["type"] == "tenderdash-rpc":
            try:
                h = min(height, ref) - 1
                mine, theirs = self.td_block(self.n["td_rpc"], h), self.td_block(refc["url"], h)
            except (OSError, ValueError, KeyError) as e:
                log("comparison not possible yet:", e)
                return
            if mine != theirs:
                return self.finish("failed", f"block {h} differs from the reference: {mine} vs {theirs}")
            run["compared"] = {"height": h, "blockHash": mine[0], "appHash": mine[1]}
        self.finish("passed")

    def follow(self):
        """After a pass: keep the picture current, nothing is decided here."""
        td = self.td_status()
        run = self.state["run"]
        passed_at = (self.state.get("last_passed") or {}).get("height") or 0
        if td and td["height"] < passed_at - 100:
            # The state is in memory, so a reboot empties it and the containers start
            # again from block 1. That would be a replay nobody asked for: stop it.
            log(f"the node is at {td['height']}, below the {passed_at} it passed at: state lost, stopping it")
            self.compose("stop", *PLATFORM_SERVICES, check=False)
            self.state["phase"] = "idle"
            self.state["last_request"] = {"id": None, "result": "stopped", "finishedAt": iso(),
                                          "reason": "Platform state was lost (reboot); the next run rebuilds it"}
            return
        if run and td:
            run.update(height=td["height"], referenceHeight=self.reference_height())
        states = {s: self.inspect(s) for s in PLATFORM_SERVICES}
        self.state["following_healthy"] = bool(td) and all(c and c["status"] == "running" for c in states.values())
        f = self.state.setdefault("following", {"since": iso(), "bytes": {}})
        if self.last_counters is None:
            self.last_counters = self.counters()  # the daemon was restarted: count from here
        else:
            self.add_bytes(f["bytes"])

    def publish(self):
        run = self.state.get("run") or {}
        speed = rate(list(self.samples)) if self.state["phase"] in RUNNING else None
        ref, h = run.get("referenceHeight"), run.get("height")
        core = self.core_cli("getblockchaininfo")
        out = {
            "schema": 1, "network": self.net, "updatedAt": iso(), "phase": self.state["phase"],
            "hold": self.hold(), "height": h, "referenceHeight": ref,
            "progress": round(min(1.0, h / ref), 4) if h and ref else None,
            "blocksPerSecond": round(speed, 2) if speed else None,
            "etaSeconds": int((ref - h) / speed) if speed and ref and h is not None and ref > h else None,
            "healthy": self.state.get("following_healthy") if self.state["phase"] == "following" else None,
            "core": {"height": core.get("blocks"), "headers": core.get("headers"),
                     "syncing": bool(core.get("initialblockdownload"))} if isinstance(core, dict) else None,
            "run": run or None, "lastRequest": self.state.get("last_request"),
            "lastPassed": self.state.get("last_passed"), "following": self.state.get("following"),
            "disk": self.disk(),
        }
        os.makedirs(self.status_dir, exist_ok=True)
        write_json(f"{self.status_dir}/{self.net}.json", out, 0o644)
        write_json(self.state_file, self.state)
        self.report(out)

    def report(self, out):
        """Posts the status to the status console, on a change of phase and every few minutes."""
        r = self.cfg["report"]
        when, phase, last_error = self.reported
        if not r.get("url") or (phase == out["phase"] and time.time() - when < r["every_seconds"]):
            return
        try:
            with open(r["token_file"]) as f:
                token = f.read().strip()
        except OSError:
            return
        error = None
        try:
            req = urllib.request.Request(r["url"], data=json.dumps(out).encode(), method="POST", headers={
                "Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": "platform-sync"})
            urllib.request.urlopen(req, timeout=15).close()
        except urllib.error.HTTPError as e:
            error = f"HTTP {e.code}"
        except OSError as e:
            error = str(e)[:120]
        if error != last_error:
            log("status console report:", error or "accepted")
        self.reported = (time.time(), out["phase"], error)

    def tick(self):
        phase = self.state["phase"]
        if phase in RUNNING and (self.state.get("run") or {}).get("startedAt"):
            self.watch()
        elif phase == "starting":
            # The daemon died between wiping and starting. The data is gone either way.
            self.finish("failed", "interrupted while starting")
        else:
            if phase == "following":
                self.follow()
            req = self.next_request()
            if req:
                self.start_run(req)
        self.publish()

    def daemon(self):
        log(f"platform-sync {self.net}: phase {self.state['phase']}, project {self.project}")
        n = 0
        while True:
            try:
                self.tick()
            except Exception as e:  # one bad tick must not end the daemon
                log("tick failed:", repr(e)[:500])
            n += 1
            if n % 120 == 0:
                self.sweep_spool()
            time.sleep(self.cfg["tick_seconds"])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--config", default="/etc/platform-sync/config.json")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("daemon", "status", "release", "resolve"):
        sub.add_parser(name).add_argument("--network", required=True, choices=("testnet", "mainnet"))
    h = sub.add_parser("hold")
    h.add_argument("--network", required=True, choices=("testnet", "mainnet"))
    h.add_argument("reason")
    r = sub.add_parser("request", help="queue a run from the host itself")
    r.add_argument("--network", required=True, choices=("testnet", "mainnet"))
    r.add_argument("--image", default="auto")
    r.add_argument("--tenderdash-image")
    r.add_argument("--force", action="store_true")
    a = p.parse_args(argv)
    cfg = load_config(a.config)
    s = Sync(cfg, a.network)
    if a.cmd == "daemon":
        s.daemon()
    elif a.cmd == "status":
        print(json.dumps(read_json(f"{s.status_dir}/{a.network}.json"), indent=1))
    elif a.cmd == "resolve":
        print(json.dumps(s.resolve_auto(), indent=1))
    elif a.cmd == "hold":
        with open(s.hold_file, "w") as f:
            f.write(a.reason + "\n")
        print(f"{a.network}: on hold, requests are refused until 'release'")
    elif a.cmd == "release":
        Sync._unlink(s.hold_file)
        print(f"{a.network}: hold cleared")
    elif a.cmd == "request":
        rid = f"manual-{now().strftime('%Y%m%dT%H%M%SZ')}-{a.network}"
        req = validate_request({"id": rid, "network": a.network, "image": a.image,
                                "tenderdash_image": a.tenderdash_image, "force": a.force}, a.network)
        write_json(f"{s.requests}/{rid}.json", req, 0o644)
        print(rid)


if __name__ == "__main__":
    sys.exit(main())
