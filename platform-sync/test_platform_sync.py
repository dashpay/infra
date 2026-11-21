"""python3 -m unittest platform-sync/test_platform_sync.py"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import platform_sync as ps  # noqa: E402

SHA = "a" * 40


class ValidateRequest(unittest.TestCase):
    def ok(self, **kw):
        return ps.validate_request({"id": "gh-1-1-testnet", "network": "testnet", **kw}, "testnet")

    def test_defaults_to_auto(self):
        self.assertEqual(self.ok(), {"id": "gh-1-1-testnet", "network": "testnet", "force": False,
                                     "image": "auto", "tenderdash_image": None})

    def test_allowed_images(self):
        for image in ("dashpay/drive:5.1.0-dev.2", "dashpay/drive@sha256:" + "0" * 64,
                      f"ghcr.io/dashpay/platform/nightly/drive:sha-{SHA}"):
            self.assertEqual(self.ok(image=image)["image"], image)
        self.assertEqual(self.ok(tenderdash_image="dashpay/tenderdash:2.0.0-dev.3")["tenderdash_image"],
                         "dashpay/tenderdash:2.0.0-dev.3")

    def test_refused_images(self):
        for image in ("evil/drive:1", "docker.io/evil/drive:1", "dashpay/drive", "dashpay/drive:1 --privileged",
                      "dashpay/drive:$(id)", "ghcr.io/other/drive:1", "dashpay/dashd:24", "-v/:/host",
                      "dashpay/tenderdash:1.8", "123456789012.dkr.ecr.eu-west-1.amazonaws.com/drive:x", 7, ["x"]):
            with self.assertRaises(ValueError, msg=repr(image)):
                self.ok(image=image)
        with self.assertRaises(ValueError):
            self.ok(tenderdash_image="dashpay/drive:5")

    def test_refused_envelopes(self):
        for req in ("x", None, {"id": "../x", "network": "testnet"}, {"id": "", "network": "testnet"},
                    {"id": "a" * 65, "network": "testnet"}, {"id": "ok", "network": "mainnet"},
                    {"id": "ok"}, {"id": 5, "network": "testnet"}):
            with self.assertRaises(ValueError, msg=repr(req)):
                ps.validate_request(req, "testnet")

    def test_force_must_be_true(self):
        self.assertTrue(self.ok(force=True)["force"])
        self.assertFalse(self.ok(force="yes")["force"])


class Helpers(unittest.TestCase):
    def test_sum_p2p_bytes(self):
        page = "\n".join([
            "# HELP tenderdash_p2p_peer_receive_bytes_total bytes",
            'tenderdash_p2p_peer_receive_bytes_total{chain_id="x",peer_id="a",message_type="b"} 1000',
            'tenderdash_p2p_peer_receive_bytes_total{chain_id="x",peer_id="c",message_type="b"} 2.5e+03',
            'tenderdash_p2p_peer_send_bytes_total{chain_id="x",peer_id="a",message_type="b"} 40',
            # Tenderdash books received messages again as "sent" with no peer: not traffic.
            'tenderdash_p2p_peer_send_bytes_total{chain_id="x",peer_id="",message_type="b"} 3500',
            "tenderdash_p2p_peers 2", "garbage"])
        self.assertEqual(ps.sum_p2p_bytes(page), (3500, 40))

    def test_parse_rule_bytes(self):
        tag = "platform-sync-testnet"
        listing = "\n".join([
            "-N DOCKER-USER",
            "-A DOCKER-USER -s 172.30.25.0/24 ! -d 172.16.0.0/12 -c 454651 27531554 -j REJECT --reject-with icmp-net-prohibited",
            "-A DOCKER-USER -s 172.30.24.0/24 ! -d 172.16.0.0/12 -m comment --comment platform-sync-testnet-out -c 12 3456",
            '-A DOCKER-USER ! -s 172.16.0.0/12 -d 172.30.24.0/24 -m comment --comment "platform-sync-testnet-in" -c 9 7890',
            "-A DOCKER-USER -s 172.30.25.0/24 ! -d 172.16.0.0/12 -m comment --comment platform-sync-mainnet-out -c 1 1"])
        self.assertEqual(ps.parse_rule_bytes(listing, tag), {"internetTx": 3456, "internetRx": 7890})
        self.assertEqual(ps.parse_rule_bytes("-N DOCKER-USER", tag), {})
        rules = ps.counting_rules("172.30.24.0/24", tag)
        self.assertEqual(rules["internetTx"][:4], ["-s", "172.30.24.0/24", "!", "-d"])
        self.assertEqual(rules["internetRx"][-1], tag + "-in")

    def test_rate(self):
        self.assertIsNone(ps.rate([(0, 10)]))
        self.assertEqual(ps.rate([(0, 0), (100, 2000)]), 20)
        # Only the window counts.
        self.assertEqual(ps.rate([(0, 0), (1000, 100), (1300, 3100)], window=600), 10)

    def test_find_fatal(self):
        log = "ok\nE[1] wrong Block.Header.AppHash. Expected AA, got BB module=consensus\nmore"
        self.assertEqual(ps.find_fatal(log),
                         ("AppHash mismatch", "E[1] wrong Block.Header.AppHash. Expected AA, got BB module=consensus"))
        self.assertEqual(ps.find_fatal("CONSENSUS FAILURE")[0], "Tenderdash consensus failure")
        self.assertIsNone(ps.find_fatal("all good\n"))

    def test_sh_timeout_is_a_failure_not_an_exception(self):
        slow = [sys.executable, "-c", "import time; time.sleep(5)"]
        self.assertEqual(ps.sh(slow, check=False, timeout=0.2).returncode, 124)
        with self.assertRaises(RuntimeError):
            ps.sh(slow, timeout=0.2)

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW") and hasattr(os, "fchmod"), "POSIX only")
    def test_write_json_never_follows_a_planted_link(self):
        with tempfile.TemporaryDirectory() as d:
            victim = os.path.join(d, "victim")
            with open(victim, "w") as f:
                f.write("keep")
            target = os.path.join(d, "spool", "r.json")
            os.mkdir(os.path.dirname(target))
            os.symlink(victim, target)  # the final name is a link: it is replaced, not followed
            ps.write_json(target, {"a": 1}, 0o644)
            self.assertFalse(os.path.islink(target))
            self.assertEqual(ps.read_json(target), {"a": 1})
            with open(victim) as f:
                self.assertEqual(f.read(), "keep")
            self.assertEqual(os.listdir(os.path.dirname(target)), ["r.json"])  # no temporary file left

    def test_merge(self):
        self.assertEqual(ps.merge({"a": {"b": 1, "c": 2}, "d": 3}, {"a": {"b": 9}}), {"a": {"b": 9, "c": 2}, "d": 3})

    def test_registry_host(self):
        self.assertEqual((ps.Registry("dashpay/drive").host, ps.Registry("dashpay/drive").repo),
                         ("registry-1.docker.io", "dashpay/drive"))
        r = ps.Registry("ghcr.io/dashpay/platform/ci/drive")
        self.assertEqual((r.host, r.repo), ("ghcr.io", "dashpay/platform/ci/drive"))


if __name__ == "__main__":
    unittest.main()
