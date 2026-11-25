#!/usr/bin/env python3
"""release-watch: replay every dev and rc release of Platform, without being asked.

Run every two minutes by a systemd timer. For each new release of
dashpay/platform whose tag is a dev or rc build it

  1. says so (one message, and everything later goes in its thread),
  2. waits until the release workflow has published the Drive image,
  3. asks the platform-sync daemons for a replay on every network,
  4. passes on each network's result.

It only writes request files and reads result files: the same door the GitHub
runner uses. What a request may contain is decided by platform_sync.py.

The host has no public address, so a GitHub webhook cannot reach it. The watcher
asks instead: the releases feed for new tags, Docker Hub for the image, and the
GitHub API (without a token, a few calls an hour) for the state of CI.

Python standard library only. The operating guide is README.md in this directory.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import platform_sync as ps  # noqa: E402

DEFAULTS = {
    "repository": "dashpay/platform",
    # Which releases are replayed. Stable releases are not: they were replayed as rc builds.
    "tag_pattern": r"^v\d+\.\d+\.\d+-(dev|rc)\.\d+$",
    "workflow": ".github/workflows/release.yml",
    # The jobs of that workflow that build and publish the image a replay needs.
    "image_job": "Release Drive image",
    "image": "dashpay/drive",
    "networks": ["testnet", "mainnet"],
    "ci_poll_seconds": 600,       # how often CI is asked while the image is not on Docker Hub
    "ci_confirm_seconds": 300,    # and once it is
    "ci_unreadable_minutes": 45,  # image on Docker Hub but GitHub does not answer: start after this long
    "give_up_hours": 72,          # no image this long after the release: stop waiting
    "result_wait_hours": 26,      # the daemon ends a replay after 20 hours by itself
    # Messages go to Slack through an MCP server that has a post_message tool
    # (set all three in /etc/platform-sync/config.json). Until then the watcher only logs.
    "notify": {"mcp_url": None, "bearer_file": None, "channel": None},
}
UA = "platform-sync-release-watch"
ATOM = "{http://www.w3.org/2005/Atom}"
VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z]+)\.(\d+))?$")
TENDERDASH_RE = re.compile(r"image:\s*'(dashpay/tenderdash:[A-Za-z0-9._-]+)'")
OPEN = ("waiting", "ready", "requested")
BAD = ("failure", "cancelled", "timed_out", "startup_failure", "action_required", "skipped", "stale")


# ---- pure parts ---------------------------------------------------------
def feed_tags(xml):
    """Tags in the releases feed, newest first."""
    out = []
    for entry in ET.fromstring(xml).iter(f"{ATOM}entry"):
        ident = entry.findtext(f"{ATOM}id") or ""
        tag = ident.rsplit("/", 1)[-1]
        if tag and tag not in out:
            out.append(tag)
    return out


def version_key(tag):
    """Orders the releases of one line. None for a tag that is not a version."""
    m = VERSION_RE.match(tag or "")
    if not m:
        return None
    major, minor, patch, label, n = m.groups()
    # A release without a label is newer than any prerelease of the same number.
    return (int(major), int(minor), int(patch), 1 if label is None else 0, label or "", int(n or 0))


def superseded_by(tag, others):
    """The newest other tag of the same major.minor that is newer than this one, if any."""
    mine, best = version_key(tag), None
    for other in others:
        theirs = version_key(other)
        if mine and theirs and other != tag and theirs[:2] == mine[:2] and theirs > mine:
            if best is None or theirs > version_key(best):
                best = other
    return best


def image_gate(jobs, prefix):
    """What the image jobs of a release run say: (state, detail).

    ready    all of them finished successfully, a publishing job among them
    running  some are not finished
    failed   one ended any other way
    absent   the run has no such job (yet)
    """
    mine = [j for j in jobs or [] if (j.get("name") or "") == prefix or (j.get("name") or "").startswith(prefix + " / ")]
    if not mine:
        return "absent", None
    # A job that was skipped because another one failed is not the one to name.
    for j in sorted(mine, key=lambda j: j.get("conclusion") == "skipped"):
        if j.get("status") == "completed" and j.get("conclusion") in BAD:
            return "failed", f"{j['name']}: {j['conclusion']}"
    if all(j.get("status") == "completed" and j.get("conclusion") == "success" for j in mine):
        return "ready", max((j.get("completed_at") or "") for j in mine) or None
    return "running", None


def duration(seconds):
    if seconds is None:
        return "?"
    h, m = divmod(int(seconds) // 60, 60)
    return f"{h} h {m:02d} min" if h else f"{m} min"


def esc(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def result_line(network, res):
    """One network's outcome, as Slack text. `reason` is written by the daemon and is public."""
    if res is None:
        return f"• *{network}*: no result arrived. Look at `platform_sync.py status --network {network}` on the host."
    result, reason = res.get("result"), res.get("reason")
    if result == "passed":
        line = (f"• *{network}*: passed. {res.get('height') or 0:,} blocks from genesis in "
                f"{duration(res.get('durationSeconds'))}")
        restarts = sum(v or 0 for v in (res.get("restarts") or {}).values())
        line += f", {restarts} container restart(s)." if restarts else "."
        cmp_ = res.get("compared")
        if cmp_:
            line += f" Block hash and AppHash at {cmp_['height']:,} equal the reference node's."
        return line
    if result == "failed":
        where = (f" at block {res['height']:,} of {res['referenceHeight']:,}"
                 if res.get("height") and res.get("referenceHeight") else "")
        return (f"• *{network}*: *FAILED*{where}: {esc(reason or 'no reason recorded')}. "
                f"The node is stopped and its data kept until the next run.")
    return f"• *{network}*: not run ({esc(result or 'unknown')}: {esc(reason or 'no reason given')})."


# ---- the outside world --------------------------------------------------
def get(url, headers=None, timeout=20):
    """(status, body). An HTTP error is a status, not an exception; no answer is status 0."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:2000]
    except (OSError, ValueError) as e:
        return 0, str(e).encode()


def get_json(url, headers=None):
    status, body = get(url, headers)
    try:
        return status, json.loads(body) if status == 200 else None
    except ValueError:
        return status, None


class Watch:
    def __init__(self, cfg, dry=False):
        self.c = ps.merge(DEFAULTS, cfg.get("release_watch"))
        self.root = cfg["root"]
        self.dry = dry
        self.state_file = f"{self.root}/state/release-watch.json"
        self.requests = f"{self.root}/spool/requests"
        self.status_dir = f"{self.root}/spool/status"
        self.state = ps.read_json(self.state_file)
        self.api = f"https://api.github.com/repos/{self.c['repository']}"
        self.web = f"https://github.com/{self.c['repository']}"

    def save(self):
        if not self.dry:
            ps.write_json(self.state_file, self.state)

    # ---- messages -------------------------------------------------------
    def say(self, rel, text):
        """Queued, then sent in order: a message Slack did not take is tried again next time."""
        ps.log(f"{rel['tag']}: {text}")
        rel.setdefault("outbox", []).append({"text": text, "at": ps.iso()})

    def post(self, text, thread=None):
        n = self.c["notify"]
        with open(n["bearer_file"]) as f:
            bearer = f.read().strip()
        args = {"channel": n["channel"], "text": text, "unfurl_links": False}
        if thread:
            args["thread_ts"] = thread
        body = {"jsonrpc": "2.0", "id": os.urandom(8).hex(), "method": "tools/call",
                "params": {"name": "post_message", "arguments": args}}
        req = urllib.request.Request(n["mcp_url"], data=json.dumps(body).encode(), method="POST", headers={
            "Authorization": "Bearer " + bearer, "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r:
            raw, ctype = r.read().decode(), r.headers.get("content-type", "")
        if "text/event-stream" in ctype:
            raw = [line[5:].strip() for line in raw.splitlines() if line.startswith("data:")][-1]
        d = json.loads(raw)
        res = d.get("result") or {}
        out = " ".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        if d.get("error") or res.get("isError"):
            raise RuntimeError(f"post_message refused: {str(d.get('error') or out)[:200]}")
        m = re.search(r'"ts"\s*:\s*"(\d+\.\d+)"', out)
        return m.group(1) if m else None

    def flush(self, rel):
        n = self.c["notify"]
        box = rel.get("outbox") or []
        while box:
            msg = box[0]
            if n.get("channel") and n.get("mcp_url") and n.get("bearer_file") and not self.dry:
                try:
                    ts = self.post(msg["text"], rel.get("thread"))
                except Exception as e:  # Slack being away must not hold up a replay
                    if time.time() - ps.parse_iso(msg["at"]).timestamp() < 86400:
                        ps.log(f"{rel['tag']}: message not sent, trying again later:", repr(e)[:200])
                        return
                    ps.log(f"{rel['tag']}: message dropped after a day:", msg["text"][:120])
                else:
                    if ts and not rel.get("thread"):
                        rel["thread"] = ts
            box.pop(0)

    # ---- finding releases -----------------------------------------------
    def discover(self):
        status, body = get(f"{self.web}/releases.atom")
        if status != 200:
            ps.log(f"releases feed not readable (HTTP {status})")
            return
        try:
            tags = feed_tags(body)
        except ET.ParseError as e:
            ps.log("releases feed not parseable:", e)
            return
        if self.state is None:
            # The first run starts here: nothing that is already published is replayed.
            self.state = {"schema": 1, "since": ps.iso(), "known": tags, "releases": {}}
            ps.log(f"first run: {len(tags)} published releases noted, none replayed")
            return
        for tag in reversed(tags):  # oldest first, so that messages come in order
            if tag in self.state["known"]:
                continue
            self.state["known"] = (self.state["known"] + [tag])[-200:]
            if re.match(self.c["tag_pattern"], tag) and version_key(tag):
                self.track(tag)
            else:
                ps.log(f"{tag}: published, not a tag this watcher replays")

    def track(self, tag, announce=True):
        rel = {"tag": tag, "version": tag[1:], "stage": "waiting", "seenAt": ps.iso(), "requests": {}, "results": {},
               "url": f"{self.web}/releases/tag/{tag}"}
        self.state["releases"][tag] = rel
        if announce:
            self.say(rel, f"*Platform {tag}* is published (<{rel['url']}|release>). Once CI has published "
                          f"`{self.c['image']}:{rel['version']}`, a replay from genesis starts on "
                          f"{' and '.join(self.c['networks'])}.")
        return rel

    # ---- waiting for CI -------------------------------------------------
    def hub_has(self, image, tag):
        """True, False, or None when Docker Hub cannot be asked."""
        status, d = get_json(f"https://hub.docker.com/v2/repositories/{image}/tags/{tag}")
        if status == 404:
            return False
        if status != 200 or not isinstance(d, dict):
            return None
        return any(i.get("architecture") == "amd64" and i.get("status", "active") == "active"
                   for i in d.get("images") or [])

    def read_ci(self, rel):
        """Fills rel['run'] and rel['gate'] from the GitHub API. False when it could not be read."""
        gh = {"Accept": "application/vnd.github+json"}
        status, runs = get_json(f"{self.api}/actions/runs?event=release&per_page=30", gh)
        if status != 200:
            rel["ciError"] = f"HTTP {status}"
            return False
        run = next((r for r in runs.get("workflow_runs", [])
                    if r.get("head_branch") == rel["tag"] and r.get("path") == self.c["workflow"]), None)
        if not run:
            rel["gate"] = "absent"
            rel.pop("ciError", None)
            return True
        status, jobs = get_json(f"{self.api}/actions/runs/{run['id']}/jobs?per_page=100&filter=latest", gh)
        if status != 200:
            rel["ciError"] = f"HTTP {status}"
            return False
        rel["run"] = {k: run.get(k) for k in ("id", "status", "conclusion", "run_attempt", "html_url")}
        rel["gate"], rel["gateDetail"] = image_gate(jobs.get("jobs"), self.c["image_job"])
        rel.pop("ciError", None)
        return True

    def supersede(self, rel):
        """A release that has not been requested yet gives way to a newer one of its line."""
        newer = superseded_by(rel["tag"], [t for t, r in self.state["releases"].items() if r["stage"] != "abandoned"])
        if newer and not rel["requests"]:
            rel["stage"] = "superseded"
            self.say(rel, f"Not replayed: {newer} was published before a replay of this one could start.")

    def wait_for_ci(self, rel):
        on_hub = self.hub_has(self.c["image"], rel["version"])
        if on_hub:
            rel.setdefault("imageSeenAt", ps.iso())
        every = self.c["ci_confirm_seconds"] if on_hub else self.c["ci_poll_seconds"]
        if time.time() - rel.get("ciCheckedAt", 0) >= every:
            rel["ciCheckedAt"] = int(time.time())
            if not self.read_ci(rel):
                ps.log(f"{rel['tag']}: CI not readable ({rel.get('ciError')})")
        gate, run = rel.get("gate"), rel.get("run") or {}
        if on_hub and gate == "ready":
            rel["stage"] = "ready"
            return
        if on_hub and rel.get("ciError") and (
                time.time() - ps.parse_iso(rel["imageSeenAt"]).timestamp() > self.c["ci_unreadable_minutes"] * 60):
            rel["stage"], rel["ciUnread"] = "ready", True
            return
        if gate == "failed" and run.get("status") == "completed" and rel.get("failedAttempt") != run.get("run_attempt"):
            # Said once for each attempt. A rerun that publishes the image is picked up like the first run.
            rel["failedAttempt"] = run.get("run_attempt")
            self.say(rel, f"<{run.get('html_url')}|Release CI> ended without the Drive image "
                          f"({esc(rel.get('gateDetail'))}). No replay yet; a rerun that publishes it starts one.")
        if time.time() - ps.parse_iso(rel["seenAt"]).timestamp() > self.c["give_up_hours"] * 3600:
            rel["stage"] = "abandoned"
            self.say(rel, f"Gave up after {self.c['give_up_hours']} hours: `{self.c['image']}:{rel['version']}` "
                          f"was never published. Not replayed.")

    # ---- asking for the replay ------------------------------------------
    def tenderdash(self, rel):
        """The Tenderdash image dashmate ships at this tag, once it is known to be published."""
        if rel.get("tenderdash"):
            return rel["tenderdash"]
        url = ps.DEFAULTS["auto"]["source"].format(tag=rel["version"])
        status, body = get(url)
        m = TENDERDASH_RE.search(body.decode("utf-8", "replace")) if status == 200 else None
        if not m:
            ps.log(f"{rel['tag']}: Tenderdash image not found in dashmate's defaults (HTTP {status})")
            return None
        repo, tag = m.group(1).split(":", 1)
        if self.hub_has(repo, tag) is False:
            ps.log(f"{rel['tag']}: {m.group(1)} is not on Docker Hub yet")
            return None
        rel["tenderdash"] = m.group(1)
        return rel["tenderdash"]

    def busy(self, network, rel):
        """Why a request for this network has to wait, or None."""
        status = ps.read_json(f"{self.status_dir}/{network}.json") or {}
        if status.get("hold"):
            return "on hold"
        if status.get("phase") in ps.RUNNING:
            return f"a replay is running ({(status.get('run') or {}).get('id')})"
        for other in self.state["releases"].values():
            if other is not rel and network in other["requests"] and network not in other["results"]:
                return f"{other['tag']} is not finished"
        return None

    def request(self, rel):
        td = self.tenderdash(rel)
        if not td:
            return
        image = f"{self.c['image']}:{rel['version']}"
        for network in self.c["networks"]:
            if network in rel["requests"]:
                continue
            why = self.busy(network, rel)
            if why:
                if rel.get("waitNote", {}).get(network) != why:
                    rel.setdefault("waitNote", {})[network] = why
                    ps.log(f"{rel['tag']}: {network} has to wait: {why}")
                continue
            rid = f"release-{rel['version']}-{network}"
            req = ps.validate_request({"id": rid, "network": network, "image": image, "tenderdash_image": td}, network)
            if self.dry:
                ps.log(f"{rel['tag']}: would request {req}")
                continue
            ps.write_json(f"{self.requests}/{rid}.json", req, 0o644)
            rel["requests"][network] = {"id": rid, "at": ps.iso()}
            ps.log(f"{rel['tag']}: requested {rid}")
        if all(n in rel["requests"] for n in self.c["networks"]):
            rel["stage"] = "requested"
            run = rel.get("run") or {}
            ci = (f"<{run['html_url']}|Release CI> published the Drive image" if run.get("html_url") and not rel.get("ciUnread")
                  else "The Drive image is on Docker Hub (the state of CI could not be read)")
            self.say(rel, f"{ci}. Replay from genesis requested on {' and '.join(self.c['networks'])}: "
                          f"`{image}` with `{td}`. It takes two to three hours.")

    # ---- results --------------------------------------------------------
    def collect(self, rel):
        for network, r in rel["requests"].items():
            if network in rel["results"]:
                continue
            res = ps.read_json(f"{self.status_dir}/results/{r['id']}.json")
            if res and res.get("result"):
                kept = {k: res.get(k) for k in ("id", "result", "reason", "height", "referenceHeight", "durationSeconds",
                                                "restarts", "compared", "startedAt", "finishedAt")}
                try:
                    line = result_line(network, kept)
                except (TypeError, ValueError, KeyError):  # a result file of an unexpected shape is still a result
                    line = f"• *{network}*: {esc(kept.get('result'))} ({esc(kept.get('reason') or 'no detail')})."
                rel["results"][network] = kept
                self.say(rel, line)
            elif time.time() - ps.parse_iso(r["at"]).timestamp() > self.c["result_wait_hours"] * 3600:
                rel["results"][network] = {"id": r["id"], "result": None}
                self.say(rel, result_line(network, None))
        if all(n in rel["results"] for n in rel["requests"]):
            rel["stage"] = "done"
            rel["doneAt"] = ps.iso()

    # ---- one pass -------------------------------------------------------
    def tick(self):
        self.discover()
        if self.state is None:
            return
        for rel in list(self.state["releases"].values()):
            try:
                if rel["stage"] in ("waiting", "ready"):
                    self.supersede(rel)
                if rel["stage"] == "waiting":
                    self.wait_for_ci(rel)
                if rel["stage"] == "ready":
                    self.request(rel)
                if rel["stage"] == "requested":
                    self.collect(rel)
            except Exception as e:  # one release must not stop the others
                ps.log(f"{rel['tag']}: step failed:", repr(e)[:400])
            self.flush(rel)
            self.save()
        # Keep what is open and the last twenty that are closed.
        closed = [t for t, r in self.state["releases"].items() if r["stage"] not in OPEN and not r.get("outbox")]
        for tag in closed[:-20]:
            del self.state["releases"][tag]
        self.save()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--config", default="/etc/platform-sync/config.json")
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tick", help="one pass; what the timer runs")
    t.add_argument("--dry-run", action="store_true", help="read everything, write nothing, send nothing")
    sub.add_parser("status", help="what is being followed")
    a = sub.add_parser("add", help="follow a release that is already published")
    a.add_argument("--tag", required=True)
    a.add_argument("--request", action="append", default=[], metavar="NETWORK=ID",
                   help="a replay of it that was already requested by hand; only its result is awaited")
    a.add_argument("--quiet", action="store_true", help="do not announce it")
    args = p.parse_args(argv)
    w = Watch(ps.load_config(args.config), dry=getattr(args, "dry_run", False))
    if args.cmd == "tick":
        w.tick()
    elif args.cmd == "status":
        s = w.state or {}
        print(json.dumps({"since": s.get("since"), "releases": [
            {k: r.get(k) for k in ("tag", "stage", "seenAt", "gate", "run", "tenderdash", "requests", "results",
                                   "waitNote", "ciError") if r.get(k) not in (None, {}, [])}
            | {"unsent": len(r.get("outbox") or [])}
            for r in (s.get("releases") or {}).values()]}, indent=1))
    elif args.cmd == "add":
        if w.state is None:
            sys.exit("no state yet: run 'tick' once first")
        if not version_key(args.tag) or not args.tag.startswith("v"):
            sys.exit("not a release tag")
        if args.tag in w.state["releases"]:
            sys.exit(f"{args.tag} is already followed")
        given = dict(x.split("=", 1) for x in args.request)
        for network, rid in given.items():
            if network not in w.c["networks"] or not ps.ID_RE.match(rid):
                sys.exit(f"bad --request {network}={rid}")
        rel = w.track(args.tag, announce=not args.quiet and not given)
        if args.tag not in w.state["known"]:
            w.state["known"].append(args.tag)
        if given:
            rel["requests"] = {n: {"id": rid, "at": ps.iso()} for n, rid in given.items()}
            rel["stage"] = "requested"
            if not args.quiet:
                w.say(rel, f"*Platform {args.tag}* (<{rel['url']}|release>): a replay from genesis is running on "
                           f"{' and '.join(given)}, started by hand. Results follow here.")
        w.flush(rel)
        w.save()
        print(f"{args.tag}: {rel['stage']}")


if __name__ == "__main__":
    sys.exit(main())
