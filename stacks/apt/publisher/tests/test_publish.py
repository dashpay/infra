"""The publisher from start to finish: publish.py as the build runs it, with
throwaway keys, releases served from a local directory and the repository in
a directory.

Needs gpg, gpgv and dpkg-deb; no root and no network. What a real apt client
makes of the result is tests/integration.sh.

Run: python -m unittest discover -s stacks/apt/publisher/tests
"""

import functools
import hashlib
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

PUBLISHER = Path(__file__).resolve().parent.parent / "publish.py"
TOOLS = ("gpg", "gpgv", "gpgconf", "dpkg-deb")


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


@unittest.skipUnless(all(shutil.which(tool) for tool in TOOLS), f"needs {', '.join(TOOLS)}")
class Publisher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.top = Path(tempfile.mkdtemp(prefix="apt-test-"))
        cls.addClassCleanup(shutil.rmtree, cls.top, ignore_errors=True)
        cls.gnupg = cls.top / "gnupg"
        cls.gnupg.mkdir(mode=0o700)
        cls.addClassCleanup(subprocess.run, ["gpgconf", "--homedir", str(cls.gnupg), "--kill", "all"], capture_output=True)

        archive = cls.new_key("Dashmate test archive <archive@example.invalid>", "cert")
        cls.gpg("--passphrase", "", "--quick-add-key", archive, "ed25519", "sign", "1y")
        listing = cls.gpg("--list-keys", "--with-colons", archive).decode().splitlines()
        subkey = next(listing[i + 1].split(":")[9] for i, line in enumerate(listing) if line.startswith("sub:"))
        (cls.top / "keyring").mkdir()
        cls.keyring = cls.top / "keyring" / "dashmate-archive-keyring.gpg"
        cls.keyring.write_bytes(cls.gpg("--export", archive))
        cls.signing_key = cls.top / "signing.key"
        cls.signing_key.write_bytes(
            cls.gpg("--pinentry-mode", "loopback", "--passphrase", "", "--export-secret-subkeys", f"{subkey}!")
        )

        cls.maintainer = cls.new_key("Test maintainer <maintainer@example.invalid>", "sign")
        cls.outsider = cls.new_key("Somebody else <outsider@example.invalid>", "sign")
        (cls.top / "maintainers").mkdir()
        (cls.top / "maintainers" / f"{cls.maintainer}.asc").write_bytes(cls.gpg("--armor", "--export", cls.maintainer))
        (cls.top / "withdrawn.txt").write_text("")

        cls.served = cls.top / "releases"
        cls.served.mkdir()
        handler = functools.partial(QuietHandler, directory=str(cls.served))
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.server.server_close)
        cls.addClassCleanup(cls.server.shutdown)

    @classmethod
    def gpg(cls, *args):
        return subprocess.run(
            ["gpg", "--homedir", str(cls.gnupg), "--batch", "--quiet", "--no-tty", *args],
            check=True, capture_output=True,
        ).stdout

    @classmethod
    def new_key(cls, user_id, usage):
        cls.gpg("--passphrase", "", "--quick-generate-key", user_id, "ed25519", usage, "1y")
        listing = cls.gpg("--list-keys", "--with-colons", user_id).decode().splitlines()
        return next(line.split(":")[9] for line in listing if line.startswith("fpr:"))

    def setUp(self):
        # Each test has its own releases and its own repository.
        self.name = self.id().rsplit(".", 1)[1]
        self.releases = self.served / self.name
        self.releases.mkdir()
        self.repo = self.top / "repos" / self.name

    # -- helpers --

    def make_release(self, tag, version, marker="first build"):
        """A release with both debs and its SHA256SUMS. Returns the sha256 of SHA256SUMS."""
        directory = self.releases / tag
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir()
        name_version = version.replace("~~", ".").replace("~", ".")
        for arch in ("amd64", "arm64"):
            root = self.top / "deb"
            shutil.rmtree(root, ignore_errors=True)
            (root / "DEBIAN").mkdir(parents=True)
            (root / "usr/share/dashmate-test").mkdir(parents=True)
            (root / "usr/share/dashmate-test/version").write_text(f"{version} {arch} {marker}\n")
            (root / "DEBIAN/control").write_text(
                f"Package: dashmate\nVersion: {version}\nSection: misc\nPriority: optional\n"
                f"Architecture: {arch}\nMaintainer: Dash Core Group <dev@dash.org>\n"
                f"Description: test package\n built for the publisher's tests\n"
            )
            subprocess.run(
                ["dpkg-deb", "--root-owner-group", "--build", str(root), str(directory / f"dashmate_{name_version}_{arch}.deb")],
                check=True, capture_output=True,
            )
        (directory / f"dashmate-{tag}-0123abcdef-linux-x64.tar.gz").write_text("not a deb\n")
        return self.write_sums(tag)

    def write_sums(self, tag):
        directory = self.releases / tag
        lines = "".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
            for path in sorted(directory.glob("dashmate*"))
        )
        (directory / "SHA256SUMS").write_text(lines)
        return hashlib.sha256(lines.encode()).hexdigest()

    def sign_release(self, tag, key):
        signature = self.releases / tag / "SHA256SUMS.asc"
        signature.unlink(missing_ok=True)
        self.gpg("--local-user", key, "--armor", "--detach-sign", "--output", str(signature), str(self.releases / tag / "SHA256SUMS"))

    def publish(self, tag="", sums_sha256=""):
        """One run of the publisher. Returns its exit status and what it logged."""
        env = {
            "PATH": os.environ["PATH"],
            "REPO_DIR": str(self.repo),
            "REPO_PREFIX": "dashmate",
            "SIGNING_KEY_FILE": str(self.signing_key),
            "ARCHIVE_KEYRING": str(self.keyring),
            "MAINTAINERS_DIR": str(self.top / "maintainers"),
            "WITHDRAWN_FILE": str(self.top / "withdrawn.txt"),
            "RELEASE_BASE_URL": f"http://127.0.0.1:{self.server.server_address[1]}/{self.name}",
            "MIN_RESIGN_AGE_HOURS": "0",
            "RELEASE_TAG": tag,
            "SHA256SUMS_SHA256": sums_sha256,
        }
        proc = subprocess.run([sys.executable, str(PUBLISHER)], env=env, capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr

    def expect(self, status, text, *request):
        got, output = self.publish(*request)
        self.assertEqual(got, status, output)
        self.assertIn(text, output)
        return output

    def tree(self):
        """Every file of the repository, by the sha256 of its content."""
        return {
            str(path.relative_to(self.repo)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(self.repo.rglob("*")) if path.is_file()
        }

    def carries(self, suite):
        """The versions a suite lists, the same for both architectures. Checks the signature first."""
        base = self.repo / "dashmate" / "dists" / suite
        subprocess.run(
            ["gpgv", "--homedir", str(self.gnupg), "--keyring", str(self.keyring), str(base / "InRelease")],
            check=True, capture_output=True,
        )
        listed = [
            sorted(
                line.split()[1]
                for line in (base / f"main/binary-{arch}/Packages").read_text().splitlines()
                if line.startswith("Version:")
            )
            for arch in ("amd64", "arm64")
        ]
        self.assertEqual(listed[0], listed[1])
        return listed[0]

    def pool(self):
        return sorted(path.name for path in (self.repo / "dashmate" / "pool").rglob("*.deb"))

    # -- the daily run --

    def test_a_refresh_takes_no_tag_and_no_sha256(self):
        self.expect(0, "stable: published, empty")
        self.assertEqual([self.carries(suite) for suite in ("stable", "testing", "dev")], [[], [], []])
        digest = self.make_release("v5.1.0-rc.1", "5.1.0~rc.1-1")
        self.expect(0, "testing: + amd64 5.1.0~rc.1-1", "v5.1.0-rc.1", digest)
        # And again with a release in it: signed again, nothing else changes.
        before = self.tree()
        self.expect(0, "testing: published, 1 version(s) [5.1.0~rc.1-1]")
        self.assertEqual(self.carries("testing"), ["5.1.0~rc.1-1"])
        signed = ("/InRelease", "/Release", "/Release.gpg")
        self.assertEqual(
            {path: digest for path, digest in self.tree().items() if not path.endswith(signed)},
            {path: digest for path, digest in before.items() if not path.endswith(signed)},
        )

    # -- a release is published from the SHA256SUMS its request names --

    def test_publishes_from_the_sums_the_request_names(self):
        digest = self.make_release("v5.1.0-rc.1", "5.1.0~rc.1-1")
        output = self.expect(0, f"v5.1.0-rc.1: SHA256SUMS is the file the request names, sha256 {digest}", "v5.1.0-rc.1", digest)
        self.assertNotIn("REFUSED", output)
        self.assertEqual(self.carries("stable"), [])
        self.assertEqual(self.carries("testing"), ["5.1.0~rc.1-1"])
        self.assertEqual(self.carries("dev"), ["5.1.0~rc.1-1"])
        self.assertEqual(self.pool(), ["dashmate_5.1.0~rc.1-1_amd64.deb", "dashmate_5.1.0~rc.1-1_arm64.deb"])
        listed = (self.releases / "v5.1.0-rc.1" / "SHA256SUMS").read_text()
        for deb in (self.repo / "dashmate" / "pool").rglob("*.deb"):
            self.assertIn(hashlib.sha256(deb.read_bytes()).hexdigest(), listed)

    def test_refuses_sums_that_were_replaced_and_writes_nothing(self):
        checked = self.make_release("v5.1.0-rc.2", "5.1.0~rc.2-1")
        # The release's debs and its SHA256SUMS are replaced after the check.
        # They agree with each other; only the request's sha256 tells.
        replaced = self.make_release("v5.1.0-rc.2", "5.1.0~rc.2-1", "another build")
        self.assertNotEqual(replaced, checked)

        # On a repository that does not exist yet: not one file.
        self.expect(2, f"REFUSED: v5.1.0-rc.2: the release's SHA256SUMS has sha256 {replaced}, and the request was made for {checked}", "v5.1.0-rc.2", checked)
        self.assertEqual(self.tree(), {})

        # On a published repository: not one byte changes. A maintainer's
        # signature on the replaced file does not stand in for the sha256.
        self.expect(0, "dev: published, empty")
        before = self.tree()
        self.assertTrue(before)
        self.expect(2, "REFUSED: v5.1.0-rc.2: the release's SHA256SUMS has sha256", "v5.1.0-rc.2", checked)
        self.sign_release("v5.1.0-rc.2", self.maintainer)
        self.expect(2, "REFUSED: v5.1.0-rc.2: the release's SHA256SUMS has sha256", "v5.1.0-rc.2", checked)
        self.assertEqual(self.tree(), before)

        # The same release is published when the request names the file that is there.
        self.expect(0, "testing: + arm64 5.1.0~rc.2-1", "v5.1.0-rc.2", replaced)
        self.assertEqual(self.carries("testing"), ["5.1.0~rc.2-1"])

    def test_refuses_sums_with_one_more_line(self):
        checked = self.make_release("v5.1.0-rc.2", "5.1.0~rc.2-1")
        (self.releases / "v5.1.0-rc.2" / "dashmate-extra.txt").write_text("added later\n")
        self.assertNotEqual(self.write_sums("v5.1.0-rc.2"), checked)
        self.expect(2, "and the request was made for", "v5.1.0-rc.2", checked)
        self.assertEqual(self.tree(), {})

    def test_refuses_a_tag_without_the_sha256_and_writes_nothing(self):
        digest = self.make_release("v5.1.0-rc.1", "5.1.0~rc.1-1")
        self.expect(2, "REFUSED: v5.1.0-rc.1: the request does not carry sha256sums_sha256", "v5.1.0-rc.1")
        self.expect(2, "REFUSED: v5.1.0-rc.1: sha256sums_sha256 must be 64 lowercase hex digits", "v5.1.0-rc.1", digest.upper())
        self.expect(2, "REFUSED: v5.1.0-rc.1: sha256sums_sha256 must be 64 lowercase hex digits", "v5.1.0-rc.1", digest[:63])
        self.expect(2, "REFUSED: a sha256 of SHA256SUMS was given without a release tag", "", digest)
        self.assertEqual(self.tree(), {})

        self.expect(0, "dev: published, empty")
        before = self.tree()
        self.expect(2, "REFUSED: v5.1.0-rc.1: the request does not carry sha256sums_sha256", "v5.1.0-rc.1")
        self.assertEqual(self.tree(), before)

    # -- stable --

    def test_stable_still_needs_a_maintainers_signature(self):
        # The right sha256 publishes a final release, but not into stable.
        digest = self.make_release("v5.1.0", "5.1.0-1")
        self.expect(0, "v5.1.0: stays out of stable until a maintainer signs SHA256SUMS", "v5.1.0", digest)
        self.assertEqual(self.carries("stable"), [])
        self.assertEqual(self.carries("testing"), ["5.1.0-1"])

        # Nor does the signature of somebody else, on a later run or on a new request.
        self.sign_release("v5.1.0", self.outsider)
        self.expect(0, "stable: 5.1.0-1 waits for a maintainer's signature on v5.1.0")
        self.expect(0, "v5.1.0: stays out of stable until a maintainer signs SHA256SUMS", "v5.1.0", digest)
        self.assertEqual(self.carries("stable"), [])

        # A maintainer signs: the next run without a tag moves it, as the daily run does.
        self.sign_release("v5.1.0", self.maintainer)
        self.expect(0, "stable: + amd64 5.1.0-1 (signed since)")
        self.assertEqual(self.carries("stable"), ["5.1.0-1"])

        # Signed before the request: straight into stable.
        digest = self.make_release("v5.1.1", "5.1.1-1")
        self.sign_release("v5.1.1", self.maintainer)
        self.expect(0, "stable: + arm64 5.1.1-1", "v5.1.1", digest)
        self.assertEqual(self.carries("stable"), ["5.1.0-1", "5.1.1-1"])

        # Signed by a maintainer, but not the SHA256SUMS the request names: nothing.
        checked = self.make_release("v5.1.2", "5.1.2-1")
        self.make_release("v5.1.2", "5.1.2-1", "another build")
        self.sign_release("v5.1.2", self.maintainer)
        before = self.tree()
        self.expect(2, "and the request was made for", "v5.1.2", checked)
        self.assertEqual(self.tree(), before)


if __name__ == "__main__":
    unittest.main()
