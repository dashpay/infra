"""python3 -m unittest platform-sync/test_platform_sync.py"""
import os
import sys
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
            "tenderdash_p2p_peers 2", "garbage"])
        self.assertEqual(ps.sum_p2p_bytes(page), (3500, 40))

    def test_rate(self):
        self.assertIsNone(ps.rate([(0, 10)]))
        self.assertEqual(ps.rate([(0, 0), (100, 2000)]), 20)
        # Only the window counts.
        self.assertEqual(ps.rate([(0, 0), (1000, 100), (1300, 3100)], window=600), 10)

    def test_merge(self):
        self.assertEqual(ps.merge({"a": {"b": 1, "c": 2}, "d": 3}, {"a": {"b": 9}}), {"a": {"b": 9, "c": 2}, "d": 3})

    def test_registry_host(self):
        self.assertEqual((ps.Registry("dashpay/drive").host, ps.Registry("dashpay/drive").repo),
                         ("registry-1.docker.io", "dashpay/drive"))
        r = ps.Registry("ghcr.io/dashpay/platform/ci/drive")
        self.assertEqual((r.host, r.repo), ("ghcr.io", "dashpay/platform/ci/drive"))


if __name__ == "__main__":
    unittest.main()
