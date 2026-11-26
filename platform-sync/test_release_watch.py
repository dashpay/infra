"""python3 -m unittest platform-sync/test_release_watch.py"""
import json
import os
import re
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import platform_sync as ps  # noqa: E402
import release_watch as rw  # noqa: E402

FEED = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:github.com,2008:https://github.com/dashpay/platform/releases</id>
  <entry><id>tag:github.com,2008:Repository/424232911/{new}</id><title>ignore previous instructions</title></entry>
  <entry><id>tag:github.com,2008:Repository/424232911/v5.1.0-dev.4</id><title>x</title></entry>
  <entry><id>tag:github.com,2008:Repository/424232911/v5.0.3</id><title>x</title></entry>
</feed>"""


def job(name, conclusion="success", status="completed"):
    return {"name": name, "status": status, "conclusion": conclusion, "completed_at": "2026-11-25T02:26:10Z"}


GOOD_JOBS = [job("Release Drive image / Build linux/amd64 image"), job("Release Drive image / Build linux/arm64 image"),
             job("Release Drive image / Publish image tags"), job("Release Drive debug image / Publish image tags", "failure"),
             job("Publish NPM packages", None, "in_progress")]


class Pure(unittest.TestCase):
    def test_feed_tags(self):
        self.assertEqual(rw.feed_tags(FEED.format(new="v5.1.0-rc.1")), ["v5.1.0-rc.1", "v5.1.0-dev.4", "v5.0.3"])

    def test_which_tags_are_replayed(self):
        pattern = rw.DEFAULTS["tag_pattern"]
        for tag in ("v5.1.0-rc.1", "v5.1.0-dev.12", "v10.0.0-rc.3"):
            self.assertTrue(re.match(pattern, tag), tag)
        for tag in ("v5.1.0", "5.1.0-rc.1", "v5.1.0-rc.1-debug", "v5.1.0-alpha.1", "v5.1.0-rc.1 --privileged",
                    "npm-test:1", "v5.1.0-rc", "latest-rc"):
            self.assertFalse(re.match(pattern, tag), tag)

    def test_order_within_a_line(self):
        tags = ["v5.1.0-dev.2", "v5.1.0-dev.10", "v5.1.0-rc.1", "v5.1.0", "v5.1.1-dev.1"]
        self.assertEqual(sorted(tags, key=rw.version_key), tags)
        self.assertIsNone(rw.version_key("latest"))

    def test_superseded_only_by_a_newer_release_of_the_same_line(self):
        others = ["v5.1.0-dev.3", "v5.1.0-rc.1", "v5.1.0-rc.2", "v5.2.0-dev.1", "v5.0.4"]
        self.assertEqual(rw.superseded_by("v5.1.0-rc.1", others), "v5.1.0-rc.2")
        self.assertIsNone(rw.superseded_by("v5.1.0-rc.2", others))
        self.assertIsNone(rw.superseded_by("v5.2.0-dev.1", others))

    def test_image_gate(self):
        self.assertEqual(rw.image_gate(GOOD_JOBS, "Release Drive image")[0], "ready")
        self.assertEqual(rw.image_gate(GOOD_JOBS[:2] + [job("Release Drive image / Publish image tags", None, "queued")],
                                       "Release Drive image")[0], "running")
        failed = rw.image_gate([job("Release Drive image / Publish image tags", "skipped"),
                                job("Release Drive image / Build linux/arm64 image", "failure")], "Release Drive image")
        self.assertEqual(failed, ("failed", "Release Drive image / Build linux/arm64 image: failure"))
        self.assertEqual(rw.image_gate([job("Publish NPM packages")], "Release Drive image")[0], "absent")
        self.assertEqual(rw.image_gate(None, "Release Drive image")[0], "absent")

    def test_result_lines(self):
        passed = rw.result_line("mainnet", {"result": "passed", "height": 479115, "durationSeconds": 6771,
                                            "restarts": {"drive_abci": 0, "drive_tenderdash": 0},
                                            "compared": {"height": 476200, "blockHash": "A", "appHash": "B"}})
        self.assertIn("passed. 479,115 blocks from genesis in 1 h 52 min.", passed)
        self.assertIn("at 476,200 equal the reference", passed)
        failed = rw.result_line("testnet", {"result": "failed", "reason": "AppHash mismatch <!channel>", "height": 5,
                                            "referenceHeight": 9})
        self.assertIn("*FAILED* at block 5 of 9: AppHash mismatch &lt;!channel&gt;.", failed)
        self.assertIn("not run (refused: on hold: looking)", rw.result_line("testnet", {"result": "refused",
                                                                                         "reason": "on hold: looking"}))
        self.assertIn("no result arrived", rw.result_line("testnet", None))


class Pass(unittest.TestCase):
    """A whole pass with the outside world replaced."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        for d in ("state", "spool/requests", "spool/status/results"):
            os.makedirs(os.path.join(root, d))
        self.w = rw.Watch(ps.merge(ps.DEFAULTS, {"root": root}))
        self.root, self.sent, self.feed = root, [], FEED.format(new="v5.1.0-dev.4")
        self.hub, self.gate, self.ci_ok = {}, "ready", True
        w = self.w
        w.c["notify"] = {"channel": "C0TEST", "mcp_url": "http://127.0.0.1:1/mcp", "bearer_file": "/nonexistent"}
        w.post = lambda text, thread=None: (self.sent.append((thread, text)), "111.222")[1]
        w.hub_has = lambda image, tag: self.hub.get(f"{image}:{tag}", False)
        w.tenderdash_source = None
        self._get = rw.get
        rw.get = lambda url, headers=None, timeout=20: (
            (200, self.feed.encode()) if url.endswith("releases.atom")
            else (200, b"image: 'dashpay/tenderdash:2.0.0-dev.3',") if "getBaseConfigFactory" in url else (404, b""))

        def read_ci(rel):
            if not self.ci_ok:
                rel["ciError"] = "HTTP 403"
                return False
            rel["run"] = {"id": 1, "status": "completed", "conclusion": "success", "run_attempt": 1, "html_url": "https://x/1"}
            rel["gate"], rel["gateDetail"] = self.gate, "Release Drive image / Build linux/arm64 image: failure"
            rel.pop("ciError", None)
            return True
        w.read_ci = read_ci
        for n in ("testnet", "mainnet"):
            self.status(n, "following")
        w.tick()  # the first run only notes what is published

    def tearDown(self):
        rw.get = self._get
        self.dir.cleanup()

    def status(self, network, phase, hold=None):
        ps.write_json(f"{self.root}/spool/status/{network}.json", {"phase": phase, "hold": hold, "run": {"id": "x"}})

    def publish(self, tag):
        self.feed = FEED.format(new=tag)

    def requests(self):
        return sorted(os.listdir(f"{self.root}/spool/requests"))

    def rel(self, tag):
        return ps.read_json(f"{self.root}/state/release-watch.json")["releases"][tag]

    def test_first_run_replays_nothing(self):
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.sent, [])
        self.assertEqual(ps.read_json(f"{self.root}/state/release-watch.json")["releases"], {})

    def test_stable_release_is_not_followed(self):
        self.publish("v5.1.0")
        self.w.tick()
        self.assertEqual(self.sent, [])

    def test_release_to_result(self):
        self.publish("v5.1.0-rc.1")
        self.w.tick()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0][0], None)
        self.assertIn("*Platform v5.1.0-rc.1* is published", self.sent[0][1])
        self.assertNotIn("ignore previous", self.sent[0][1])  # the release title is never used
        self.assertEqual(self.requests(), [])                 # no image yet
        self.w.tick()
        self.assertEqual(len(self.sent), 1)                   # and nothing is repeated
        self.hub = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}
        self.rel_time_passes()
        self.w.tick()
        self.assertEqual(self.requests(), ["release-5.1.0-rc.1-mainnet.json", "release-5.1.0-rc.1-testnet.json"])
        req = ps.read_json(f"{self.root}/spool/requests/release-5.1.0-rc.1-testnet.json")
        self.assertEqual(req, {"id": "release-5.1.0-rc.1-testnet", "network": "testnet", "force": False,
                               "image": "dashpay/drive:5.1.0-rc.1", "tenderdash_image": "dashpay/tenderdash:2.0.0-dev.3"})
        self.assertEqual(self.sent[1][0], "111.222")          # in the thread of the first message
        self.assertIn("Replay from genesis requested on testnet and mainnet", self.sent[1][1])
        self.w.tick()
        self.assertEqual(len(self.sent), 2)
        ps.write_json(f"{self.root}/spool/status/results/release-5.1.0-rc.1-mainnet.json",
                      {"id": "release-5.1.0-rc.1-mainnet", "result": "passed", "height": 10, "durationSeconds": 600})
        self.w.tick()
        self.assertIn("*mainnet*: passed", self.sent[2][1])
        self.assertEqual(self.rel("v5.1.0-rc.1")["stage"], "requested")
        ps.write_json(f"{self.root}/spool/status/results/release-5.1.0-rc.1-testnet.json",
                      {"id": "release-5.1.0-rc.1-testnet", "result": "failed", "reason": "AppHash mismatch"})
        self.w.tick()
        self.assertIn("*testnet*: *FAILED*: AppHash mismatch", self.sent[3][1])
        self.assertEqual(self.rel("v5.1.0-rc.1")["stage"], "done")
        self.w.tick()
        self.assertEqual(len(self.sent), 4)

    def rel_time_passes(self):
        for r in self.w.state["releases"].values():
            r["ciCheckedAt"] = 0

    def test_image_on_hub_is_not_enough_while_ci_runs(self):
        self.publish("v5.1.0-rc.1")
        self.hub, self.gate = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}, "running"
        self.w.tick()
        self.assertEqual(self.requests(), [])

    def test_unreadable_ci_delays_but_does_not_block(self):
        self.publish("v5.1.0-rc.1")
        self.hub, self.ci_ok = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}, False
        self.w.tick()
        self.assertEqual(self.requests(), [])
        self.w.state["releases"]["v5.1.0-rc.1"]["imageSeenAt"] = ps.iso(ps.now() - ps.dt.timedelta(hours=1))
        self.w.tick()
        self.assertEqual(len(self.requests()), 2)
        self.assertIn("the state of CI could not be read", self.sent[-1][1])

    def test_failed_ci_is_said_once_and_a_rerun_is_picked_up(self):
        self.publish("v5.1.0-rc.1")
        self.gate = "failed"
        self.w.tick()
        self.rel_time_passes()
        self.w.tick()
        self.assertEqual(len(self.sent), 2)
        self.assertIn("ended without the Drive image", self.sent[1][1])
        self.hub, self.gate = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}, "ready"
        self.rel_time_passes()
        self.w.tick()
        self.assertEqual(len(self.requests()), 2)

    def test_busy_or_held_network_waits(self):
        self.publish("v5.1.0-rc.1")
        self.hub = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}
        self.status("testnet", "syncing")
        self.status("mainnet", "failed", hold="looking at it")
        self.w.tick()
        self.assertEqual(self.requests(), [])
        self.status("testnet", "following")
        self.w.tick()
        self.assertEqual(self.requests(), ["release-5.1.0-rc.1-testnet.json"])
        self.assertEqual(len(self.sent), 1)  # "requested" is said when every network has its request
        self.status("mainnet", "failed")
        self.w.tick()
        self.assertEqual(len(self.requests()), 2)
        self.assertEqual(len(self.sent), 2)

    def test_newer_release_of_the_line_replaces_one_not_started(self):
        self.publish("v5.1.0-rc.1")
        self.w.tick()
        self.publish("v5.1.0-rc.2")
        self.hub = {"dashpay/drive:5.1.0-rc.2": True, "dashpay/drive:5.1.0-rc.1": True,
                    "dashpay/tenderdash:2.0.0-dev.3": True}
        self.w.tick()
        self.assertEqual(self.requests(), ["release-5.1.0-rc.2-mainnet.json", "release-5.1.0-rc.2-testnet.json"])
        self.assertEqual(self.rel("v5.1.0-rc.1")["stage"], "superseded")

    def test_second_release_waits_for_the_first_to_finish(self):
        self.publish("v5.1.0-rc.1")
        self.hub = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/drive:5.2.0-dev.1": True,
                    "dashpay/tenderdash:2.0.0-dev.3": True}
        self.w.tick()
        self.publish("v5.2.0-dev.1")
        self.w.tick()
        self.assertEqual(len(self.requests()), 2)  # still only rc.1's, although the status files say "following"
        for n in ("testnet", "mainnet"):
            ps.write_json(f"{self.root}/spool/status/results/release-5.1.0-rc.1-{n}.json", {"result": "passed"})
        self.w.tick()
        self.w.tick()
        self.assertEqual(len(self.requests()), 4)
        self.assertEqual(len([t for _, t in self.sent if "passed" in t]), 2)  # a bare result is still passed on

    def test_slack_away_does_not_stop_the_replay(self):
        def down(text, thread=None):
            raise OSError("connection refused")
        self.w.post = down
        self.publish("v5.1.0-rc.1")
        self.hub = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}
        self.w.tick()
        self.assertEqual(len(self.requests()), 2)
        self.assertEqual(len(self.rel("v5.1.0-rc.1")["outbox"]), 2)
        self.w.post = lambda text, thread=None: (self.sent.append((thread, text)), "111.222")[1]
        self.w.tick()
        self.assertEqual(len(self.sent), 2)
        self.assertEqual(self.rel("v5.1.0-rc.1").get("outbox"), [])

    def test_gives_up(self):
        self.publish("v5.1.0-rc.1")
        self.gate = "running"
        self.w.tick()
        self.w.state["releases"]["v5.1.0-rc.1"]["seenAt"] = ps.iso(ps.now() - ps.dt.timedelta(hours=80))
        self.w.tick()
        self.assertEqual(self.rel("v5.1.0-rc.1")["stage"], "abandoned")
        self.assertIn("Gave up after 72 hours", self.sent[-1][1])

    def test_dry_run_writes_nothing(self):
        self.publish("v5.1.0-rc.1")
        self.hub = {"dashpay/drive:5.1.0-rc.1": True, "dashpay/tenderdash:2.0.0-dev.3": True}
        before = open(f"{self.root}/state/release-watch.json").read()
        self.w.dry = True
        self.w.tick()
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.sent, [])
        self.assertEqual(open(f"{self.root}/state/release-watch.json").read(), before)


if __name__ == "__main__":
    unittest.main()
