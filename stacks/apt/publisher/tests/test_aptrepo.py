"""Rules of the repository. Run: python -m unittest discover -s stacks/apt/publisher/tests"""

import gzip
import hashlib
import lzma
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import aptrepo  # noqa: E402
from aptrepo import RepoError  # noqa: E402

DIGESTS = {"md5": "a" * 32, "sha1": "b" * 40, "sha256": "c" * 64, "sha512": "d" * 128}

CONTROL = """Package: dashmate
Version: {version}
Section: misc
Priority: optional
Architecture: {arch}
Maintainer: Dash Core Group <dev@dash.org>
Installed-Size: 512000
Description: Distribution package for Dash node installation
 built from commit 0123abcd
"""


def stanza(tag="v5.1.0", version="5.1.0-1", arch="amd64", digests=DIGESTS):
    return aptrepo.make_stanza(
        CONTROL.format(version=version, arch=arch), arch, aptrepo.parse_tag(tag), 1234, digests
    )


class Tags(unittest.TestCase):
    def test_versions_follow_the_platform_scheme(self):
        for name, upstream in {
            "v5.1.0": "5.1.0",
            "v5.1.0-rc.3": "5.1.0~rc.3",
            "v5.1.0-beta.1": "5.1.0~beta.1",
            "v5.1.0-dev.11": "5.1.0~~dev.11",
            "v5.1.0-rc.1.2": "5.1.0~rc.1.2",
        }.items():
            self.assertEqual(aptrepo.parse_tag(name).upstream, upstream)

    def test_refuses_what_is_not_a_release_tag(self):
        for name in ("", "5.1.0", "v5.1", "v5.1.0-", "v05.1.0", "v5.1.0-rc.01", "v5.1.0+build",
                     "v5.1.0-rc_1", "v5.1.0\n", "v5.1.0 ", "v5.1.0-rc.1;id", "../v5.1.0", "v٥.1.0"):
            with self.assertRaises(RepoError, msg=name):
                aptrepo.parse_tag(name)

    def test_suites(self):
        suites = lambda name, signed: aptrepo.suites_for(aptrepo.parse_tag(name), signed)
        self.assertEqual(suites("v5.1.0", True), ("stable", "testing", "dev"))
        self.assertEqual(suites("v5.1.0", False), ("testing", "dev"))
        for signed in (True, False):
            self.assertEqual(suites("v5.1.0-rc.1", signed), ("testing", "dev"))
            self.assertEqual(suites("v5.1.0-beta.2", signed), ("testing", "dev"))
            self.assertEqual(suites("v5.1.0-dev.4", signed), ("dev",))

    def test_other_prereleases_are_not_published(self):
        for name in ("v5.1.0-alpha.1", "v5.1.0-pr.1234.1", "v5.0.0-hotfix.1", "v5.1.0-1", "v5.1.0-devel.1"):
            with self.assertRaises(RepoError, msg=name):
                aptrepo.suites_for(aptrepo.parse_tag(name), True)

    def test_deb_version_must_be_the_tags(self):
        tag = aptrepo.parse_tag("v5.1.0-rc.1")
        for version in ("5.1.0~rc.1-1", "5.1.0~rc.1-12", "2:5.1.0~rc.1-1"):
            aptrepo.check_deb_version(tag, version)
        for version in ("5.1.0-1", "5.1.0~rc.1", "5.1.0~rc.10-1", "5.1.0.rc.1-1", "5.1.0~rc.1-0",
                        "5.1.0~rc.1-01", "5.1.0~~rc.1-1", "5.1.0~rc.1-1\n", "5.1.0.fd25650206-1"):
            with self.assertRaises(RepoError, msg=version):
                aptrepo.check_deb_version(tag, version)

    def test_pool_key_and_final_tag(self):
        self.assertEqual(aptrepo.pool_key("2:5.1.0~rc.1-1", "arm64"),
                         "pool/main/d/dashmate/dashmate_5.1.0~rc.1-1_arm64.deb")
        self.assertEqual(aptrepo.final_tag_of("5.1.0-2"), "v5.1.0")
        self.assertEqual(aptrepo.final_tag_of("1:5.1.0-1"), "v5.1.0")
        for version in ("5.1.0~rc.1-1", "5.1.0~~dev.1-1", "5.1.0", "5.1.0.abc-1"):
            self.assertIsNone(aptrepo.final_tag_of(version))


class Requests(unittest.TestCase):
    SUMS = b"0123  dashmate_5.1.0-1_amd64.deb\n"
    DIGEST = hashlib.sha256(SUMS).hexdigest()

    def test_no_tag_is_a_refresh(self):
        self.assertIsNone(aptrepo.parse_request("", ""))

    def test_a_release_is_named_with_the_sha256_of_its_sums(self):
        request = aptrepo.parse_request("v5.1.0-rc.2", self.DIGEST)
        self.assertEqual((request.tag.name, request.sums_sha256), ("v5.1.0-rc.2", self.DIGEST))
        aptrepo.check_sums_digest(request, self.SUMS)

    def test_refuses_a_tag_without_the_sha256(self):
        with self.assertRaisesRegex(RepoError, "does not carry sha256sums_sha256"):
            aptrepo.parse_request("v5.1.0", "")

    def test_refuses_what_is_not_a_sha256(self):
        for digest in (self.DIGEST.upper(), self.DIGEST[:-1], self.DIGEST + "0", "sha256:" + self.DIGEST,
                       self.DIGEST + "\n", " " + self.DIGEST, self.DIGEST[:-1] + "g", "0" * 63 + "٠"):
            with self.assertRaisesRegex(RepoError, "64 lowercase hex digits", msg=digest):
                aptrepo.parse_request("v5.1.0", digest)

    def test_refuses_a_sha256_without_a_tag_and_a_bad_tag(self):
        with self.assertRaisesRegex(RepoError, "without a release tag"):
            aptrepo.parse_request("", self.DIGEST)
        with self.assertRaisesRegex(RepoError, "not a release tag"):
            aptrepo.parse_request("v5.1", self.DIGEST)

    def test_a_kind_that_is_left_out_is_skipped_not_refused(self):
        for name in ("v5.1.0-alpha.1", "v5.1.0-pr.1234.1", "v5.0.0-hotfix.1"):
            with self.assertRaisesRegex(aptrepo.NotPublished, "are not published", msg=name):
                aptrepo.parse_request(name, self.DIGEST)
        # A request that is not well-formed is refused, whatever its kind.
        for request in (("v5.1.0-alpha.1", ""), ("v5.1.0-alpha.1", "0" * 63), ("v5.1.0-alpha_1", self.DIGEST)):
            with self.assertRaises(RepoError, msg=request) as caught:
                aptrepo.parse_request(*request)
            self.assertNotIsInstance(caught.exception, aptrepo.NotPublished, msg=request)

    def test_refuses_any_other_sums(self):
        request = aptrepo.parse_request("v5.1.0", self.DIGEST)
        for sums in (b"", self.SUMS[:-1], self.SUMS + b"\n", self.SUMS.replace(b"0123", b"0124")):
            with self.assertRaisesRegex(RepoError, "the request was made for " + self.DIGEST, msg=sums):
                aptrepo.check_sums_digest(request, sums)


class Sums(unittest.TestCase):
    LINES = (
        f"{'1' * 64}  dashmate-v5.1.0-rc.1-fd25650206-x64.exe\n"
        f"{'2' * 64}  dashmate_5.1.0.rc.1-1_amd64.deb\n"
        f"{'3' * 64}  dashmate_5.1.0.rc.1-1_arm64.deb\n"
    )

    def test_finds_one_deb_per_architecture(self):
        sums = aptrepo.parse_sha256sums(self.LINES.encode())
        self.assertEqual(aptrepo.release_debs(sums, aptrepo.parse_tag("v5.1.0-rc.1")), {
            "amd64": ("dashmate_5.1.0.rc.1-1_amd64.deb", "2" * 64),
            "arm64": ("dashmate_5.1.0.rc.1-1_arm64.deb", "3" * 64),
        })

    def test_dev_builds_have_one_dot_in_the_name(self):
        sums = {"dashmate_5.1.0.dev.4-1_amd64.deb": "2" * 64, "dashmate_5.1.0.dev.4-1_arm64.deb": "3" * 64}
        self.assertEqual(set(aptrepo.release_debs(sums, aptrepo.parse_tag("v5.1.0-dev.4"))), {"amd64", "arm64"})

    def test_refuses_a_release_of_another_version_or_with_two_revisions(self):
        sums = aptrepo.parse_sha256sums(self.LINES.encode())
        with self.assertRaises(RepoError):
            aptrepo.release_debs(sums, aptrepo.parse_tag("v5.1.0-rc.2"))
        with self.assertRaises(RepoError):
            aptrepo.release_debs(sums, aptrepo.parse_tag("v5.1.0"))
        sums["dashmate_5.1.0.rc.1-2_amd64.deb"] = "4" * 64
        with self.assertRaises(RepoError):
            aptrepo.release_debs(sums, aptrepo.parse_tag("v5.1.0-rc.1"))

    def test_refuses_malformed_files(self):
        good = f"{'1' * 64}  dashmate_5.1.0-1_amd64.deb\n"
        for data in (b"", good.encode()[:-1], (good + good).encode(), good.replace("  ", " ").encode(),
                     good.replace("1" * 64, "G" * 64).encode(), (good + "\n").encode(),
                     f"{'1' * 64}  ../dashmate.deb\n".encode(), f"{'1' * 64}  other.deb\n".encode(),
                     good.encode() + b"\xff\n", f"{'1' * 64}  dashmate a.deb\n".encode()):
            with self.assertRaises(RepoError, msg=data):
                aptrepo.parse_sha256sums(data)


class Packages(unittest.TestCase):
    def test_stanza_carries_the_control_file_and_the_pool_path(self):
        made = stanza()
        self.assertTrue(made.text.startswith("Package: dashmate\nVersion: 5.1.0-1\n"))
        self.assertIn("\n built from commit 0123abcd\nFilename: pool/main/d/dashmate/dashmate_5.1.0-1_amd64.deb\n", made.text)
        self.assertTrue(made.text.endswith(f"Size: 1234\nMD5sum: {'a' * 32}\nSHA1: {'b' * 40}\nSHA256: {'c' * 64}\nSHA512: {'d' * 128}\n"))
        self.assertEqual(made.version, "5.1.0-1")

    def test_refuses_a_deb_that_is_not_ours(self):
        tag = aptrepo.parse_tag("v5.1.0")
        good = CONTROL.format(version="5.1.0-1", arch="amd64")
        for control in (
            good.replace("Package: dashmate", "Package: openssh-server"),
            good.replace("Architecture: amd64", "Architecture: all"),
            good.replace("Version: 5.1.0-1", "Version: 5.2.0-1"),
            good + "Filename: pool/evil.deb\n",
            good + "SHA256: " + "0" * 64 + "\n",
            good + "\nPackage: second\n",
            good.replace("Section: misc\n", "Section: misc\nSection: other\n"),
            good.replace("Section: misc", "Section: misc\r"),
            "",
        ):
            with self.assertRaises(RepoError, msg=control):
                aptrepo.make_stanza(control, "amd64", tag, 1234, DIGESTS)

    def test_packages_round_trip(self):
        packages = {}
        for tag, version in (("v5.1.0-rc.1", "5.1.0~rc.1-1"), ("v5.1.0", "5.1.0-1"), ("v5.1.0-dev.4", "5.1.0~~dev.4-1")):
            self.assertTrue(aptrepo.add_stanza(packages, stanza(tag, version)))
        rendered = aptrepo.render_packages(packages)
        again = aptrepo.parse_packages(rendered, "amd64")
        self.assertEqual(set(again), set(packages))
        self.assertEqual(aptrepo.render_packages(again), rendered)
        self.assertEqual(rendered.count(b"\n\n"), 2)
        self.assertEqual(aptrepo.render_packages({}), b"")
        self.assertEqual(aptrepo.parse_packages(b"", "amd64"), {})

    def test_a_version_is_published_once(self):
        packages = {}
        aptrepo.add_stanza(packages, stanza())
        self.assertFalse(aptrepo.add_stanza(packages, stanza()))
        with self.assertRaises(RepoError):
            aptrepo.add_stanza(packages, stanza(digests={**DIGESTS, "sha256": "e" * 64}))

    def test_refuses_an_index_that_points_outside_the_pool(self):
        text = stanza().text
        for data in (
            text.replace("dashmate_5.1.0-1_amd64.deb", "dashmate_5.1.0-2_amd64.deb"),
            text.replace("pool/main/d/dashmate/", "pool/main/d/other/"),
            text.replace("Architecture: amd64", "Architecture: arm64"),
            text + "\n" + text,
            text.replace("Size: 1234", "Size: big"),
        ):
            with self.assertRaises(RepoError, msg=data):
                aptrepo.parse_packages(data.encode(), "amd64")

    def test_index_files(self):
        data = aptrepo.render_packages({"5.1.0-1": stanza()})
        files = aptrepo.index_files(data)
        self.assertEqual(files["Packages"], data)
        self.assertEqual(gzip.decompress(files["Packages.gz"]), data)
        self.assertEqual(lzma.decompress(files["Packages.xz"]), data)
        self.assertEqual(files["Packages.gz"], aptrepo.index_files(data)["Packages.gz"])
        self.assertEqual(gzip.decompress(aptrepo.index_files(b"")["Packages.gz"]), b"")


class Releases(unittest.TestCase):
    NOW = datetime(2026, 11, 25, 12, 0, 5, tzinfo=timezone.utc)

    def test_release(self):
        files = {"main/binary-arm64/Packages": b"", "main/binary-amd64/Packages": b"x\n"}
        text = aptrepo.render_release("stable", files, self.NOW, 10).decode()
        self.assertIn("Suite: stable\nCodename: stable\n", text)
        self.assertIn("Date: Wed, 25 Nov 2026 12:00:05 UTC\nValid-Until: Sat, 05 Dec 2026 12:00:05 UTC\n", text)
        self.assertIn("Architectures: amd64 arm64\nComponents: main\n", text)
        self.assertIn("Acquire-By-Hash: yes\nSHA256:\n", text)
        self.assertTrue(text.endswith(
            f" {hashlib.sha256(b'x' + bytes([10])).hexdigest()}                2 main/binary-amd64/Packages\n"
            f" {hashlib.sha256(b'').hexdigest()}                0 main/binary-arm64/Packages\n"
        ))
        parsed = aptrepo.parse_release(text.encode())
        self.assertEqual(parsed.date, self.NOW)
        self.assertEqual(parsed.suite, "stable")
        self.assertEqual((parsed.valid_until - parsed.date).days, 10)
        self.assertEqual(parsed.sha256["main/binary-arm64/Packages"], (hashlib.sha256(b"").hexdigest(), 0))

    def test_refuses_unknown_suites_and_broken_releases(self):
        with self.assertRaises(RepoError):
            aptrepo.render_release("oldstable", {}, self.NOW, 10)
        good = aptrepo.render_release("dev", {"main/binary-amd64/Packages": b""}, self.NOW, 10).decode()
        for text in (good.replace("Date: Wed, 25 Nov", "Date: Wed, 25 Foo"), good.replace("SHA256:", "MD5Sum:"),
                     good.replace("Suite: dev\n", ""), good.replace(" main/binary", "main/binary")):
            with self.assertRaises(RepoError, msg=text):
                aptrepo.parse_release(text.encode())

    def test_dates(self):
        self.assertEqual(aptrepo.format_date(datetime(2027, 1, 3, 4, 5, 6, tzinfo=timezone.utc)), "Sun, 03 Jan 2027 04:05:06 UTC")
        self.assertEqual(aptrepo.parse_date("Sun, 03 Jan 2027 04:05:06 UTC"), datetime(2027, 1, 3, 4, 5, 6, tzinfo=timezone.utc))
        for text in ("Sun, 3 Jan 2027 04:05:06 UTC", "Sun, 03 Jan 2027 04:05:06 GMT", "Sun, 32 Jan 2027 04:05:06 UTC"):
            with self.assertRaises(RepoError):
                aptrepo.parse_date(text)


if __name__ == "__main__":
    unittest.main()
