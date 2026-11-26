#!/usr/bin/env python3
"""Publish the dashmate apt repository. One run, start to finish:

1. Read every suite as it is published and check it against our own
   signature. Nothing unsigned is ever carried into a new index.
2. With RELEASE_TAG and SHA256SUMS_SHA256: take that release's SHA256SUMS
   from GitHub and refuse it unless it is the file the request names by its
   sha256. Then take the release's debs, check them against it, put them in
   the pool and add them to the suites the release belongs in.
3. Move final releases that a maintainer has signed since from `testing` into
   `stable`.
4. Write, sign and upload each suite whose content changed or whose Release
   is older than MIN_RESIGN_AGE_HOURS, so Valid-Until never runs out.

The signing key is read from Secrets Manager into a throwaway GnuPG home. The
rules (which release goes where, what a valid index looks like) are in
aptrepo.py; this file does the I/O. Standard library only: nothing is
installed at run time in the job that holds the key.

Exit status: 0 done, 1 published but something needs a person, 2 refused.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

import aptrepo
from aptrepo import ARCHITECTURES, SUITES, RepoError, Stanza

HERE = Path(__file__).resolve().parent

IMMUTABLE = "public, max-age=31536000, immutable"
SHORT = "public, max-age=60"
TEXT = "text/plain; charset=utf-8"
BINARY = "application/octet-stream"
DEB = "application/vnd.debian.binary-package"

SUMS_LIMIT = 64 * 1024
DEB_LIMIT = 512 * 1024 * 1024

# Hash algorithms a signature may use, by OpenPGP number: SHA-256, -384, -512.
STRONG_HASHES = {"8", "9", "10"}


class FetchError(RepoError):
    """The release could not be read. Says nothing about the release itself."""


def log(message: str) -> None:
    print(message, flush=True)


def run(args: list[str], *, check: bool = True, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    proc = subprocess.run(args, input=stdin, capture_output=True)
    if check and proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()[-2000:]
        raise RepoError(f"{args[0]} failed with exit status {proc.returncode}: {detail}")
    return proc


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --- configuration -----------------------------------------------------------


@dataclass(frozen=True)
class Config:
    bucket: str | None
    directory: str | None
    prefix: str
    signing_secret_id: str | None
    signing_key_file: str | None
    archive_keyring: Path
    maintainers: Path
    release_base_url: str
    release_tag: str
    sums_sha256: str
    withdrawn: Path
    valid_days: int
    min_resign_age: timedelta

    @classmethod
    def from_env(cls) -> "Config":
        env = os.environ.get
        config = cls(
            bucket=env("REPO_BUCKET") or None,
            directory=env("REPO_DIR") or None,
            prefix=env("REPO_PREFIX", "").strip("/"),
            signing_secret_id=env("SIGNING_SECRET_ID") or None,
            signing_key_file=env("SIGNING_KEY_FILE") or None,
            archive_keyring=Path(env("ARCHIVE_KEYRING") or HERE / "keyring" / "dashmate-archive-keyring.gpg"),
            maintainers=Path(env("MAINTAINERS_DIR") or HERE / "maintainers"),
            release_base_url=env("RELEASE_BASE_URL", "https://github.com/dashpay/platform/releases/download").rstrip("/"),
            release_tag=env("RELEASE_TAG", "").strip(),
            sums_sha256=env("SHA256SUMS_SHA256", "").strip(),
            withdrawn=Path(env("WITHDRAWN_FILE") or HERE / "withdrawn.txt"),
            valid_days=int(env("VALID_DAYS", "10")),
            min_resign_age=timedelta(hours=float(env("MIN_RESIGN_AGE_HOURS", "12"))),
        )
        if (config.bucket is None) == (config.directory is None):
            raise RepoError("set exactly one of REPO_BUCKET and REPO_DIR")
        if (config.signing_secret_id is None) == (config.signing_key_file is None):
            raise RepoError("set exactly one of SIGNING_SECRET_ID and SIGNING_KEY_FILE")
        if not 1 <= config.valid_days <= 14:
            raise RepoError("VALID_DAYS must be between 1 and 14")
        return config


# --- storage -------------------------------------------------------------------


class S3Storage:
    """The repository in S3, through the AWS CLI that the build image carries."""

    def __init__(self, bucket: str, prefix: str, work: Path):
        self.bucket = bucket
        self.prefix = prefix
        self.work = work

    def _key(self, path: str) -> str:
        return f"{self.prefix}/{path}" if self.prefix else path

    def _s3api(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return run(["aws", "s3api", *args, "--bucket", self.bucket, "--output", "json"], check=check)

    def get(self, path: str) -> bytes | None:
        target = self.work / "s3-get"
        proc = self._s3api("get-object", "--key", self._key(path), str(target), check=False)
        if proc.returncode != 0:
            error = proc.stderr.decode("utf-8", "replace")
            if "(NoSuchKey)" in error:
                return None
            raise RepoError(f"could not read s3://{self.bucket}/{self._key(path)}: {error.strip()[-500:]}")
        data = target.read_bytes()
        target.unlink()
        return data

    def exists_any(self, path_prefix: str) -> bool:
        proc = self._s3api("list-objects-v2", "--prefix", self._key(path_prefix), "--max-keys", "1")
        listing = json.loads(proc.stdout or b"{}")
        return bool(listing.get("Contents"))

    def put(self, path: str, data: bytes, content_type: str, cache_control: str) -> None:
        source = self.work / "s3-put"
        source.write_bytes(data)
        self._s3api(
            "put-object", "--key", self._key(path), "--body", str(source),
            "--content-type", content_type, "--cache-control", cache_control,
        )
        source.unlink()

    def put_file_once(self, path: str, source: Path, sha256: str, content_type: str, cache_control: str) -> bool:
        """Store a file that must never change. True if it was written now.

        S3 checks the body against the hash, and refuses the write if the key
        exists. An existing object must then be the same bytes.
        """
        checksum = base64.b64encode(bytes.fromhex(sha256)).decode("ascii")
        proc = self._s3api(
            "put-object", "--key", self._key(path), "--body", str(source),
            "--content-type", content_type, "--cache-control", cache_control,
            "--checksum-algorithm", "SHA256", "--checksum-sha256", checksum,
            "--if-none-match", "*",
            check=False,
        )
        if proc.returncode == 0:
            return True
        error = proc.stderr.decode("utf-8", "replace")
        if "(PreconditionFailed)" not in error:
            raise RepoError(f"could not write s3://{self.bucket}/{self._key(path)}: {error.strip()[-500:]}")
        head = json.loads(self._s3api("head-object", "--key", self._key(path), "--checksum-mode", "ENABLED").stdout)
        if head.get("ChecksumSHA256") != checksum:
            raise RepoError(f"{path} is already in the pool with other content; a pool file is never replaced")
        return False


class LocalStorage:
    """The repository in a directory. For tests, and for looking at a run's output."""

    def __init__(self, directory: str, prefix: str):
        self.root = Path(directory) / prefix if prefix else Path(directory)

    def get(self, path: str) -> bytes | None:
        target = self.root / path
        return target.read_bytes() if target.is_file() else None

    def exists_any(self, path_prefix: str) -> bool:
        target = self.root / path_prefix
        return target.is_dir() and any(item.is_file() for item in target.rglob("*"))

    def put(self, path: str, data: bytes, content_type: str, cache_control: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def put_file_once(self, path: str, source: Path, sha256: str, content_type: str, cache_control: str) -> bool:
        target = self.root / path
        if target.exists():
            if sha256_hex(target.read_bytes()) != sha256:
                raise RepoError(f"{path} is already in the pool with other content; a pool file is never replaced")
            return False
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        return True


# --- OpenPGP ---------------------------------------------------------------------


class Gpg:
    """gpg and gpgv in a GnuPG home that lives as long as the run."""

    def __init__(self, work: Path):
        self.work = work
        self.home = work / "gnupg"
        self.home.mkdir(mode=0o700)

    def _gpg(self, *args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
        return run(["gpg", "--homedir", str(self.home), "--batch", "--no-tty", *args], stdin=stdin)

    def close(self) -> None:
        run(["gpgconf", "--homedir", str(self.home), "--kill", "all"], check=False)

    def key_records(self, *args: str) -> list[dict]:
        """Keys and subkeys of a colon listing: kind, fingerprint, capabilities, secret."""
        records: list[dict] = []
        for line in self._gpg("--with-colons", "--with-fingerprint", "--with-fingerprint", *args).stdout.decode().splitlines():
            parts = line.split(":")
            if parts[0] in ("pub", "sec", "sub", "ssb"):
                records.append({
                    "kind": parts[0],
                    "capabilities": parts[11].lower(),
                    # `#` marks a key whose secret part is not there.
                    "secret": parts[0] in ("sec", "ssb") and parts[14] != "#",
                    "fingerprint": None,
                })
            elif parts[0] == "fpr" and records and records[-1]["fingerprint"] is None:
                records[-1]["fingerprint"] = parts[9]
        return records

    def public_primary(self, keyfile: Path) -> str:
        """The fingerprint of the one public key in a file. Refuses secret keys."""
        records = self.key_records("--show-keys", str(keyfile))
        primaries = [record for record in records if record["kind"] in ("pub", "sec")]
        if len(primaries) != 1 or primaries[0]["kind"] != "pub" or any(r["kind"] == "ssb" for r in records):
            raise RepoError(f"{keyfile.name} must hold exactly one public key and no secret key")
        return primaries[0]["fingerprint"]

    def dearmor(self, armored: bytes) -> bytes:
        return self._gpg("--dearmor", stdin=armored).stdout

    def valid_signers(self, keyring: Path, signature: Path, data: Path | None = None) -> list[str]:
        """Primary-key fingerprints of the valid signatures, checked with gpgv as apt does.

        A signature by a key that is not in the keyring is not an error: it is
        simply not one of ours. A signature that does not match the data, or
        is expired, revoked or made with a weak hash, is refused.
        """
        args = ["gpgv", "--homedir", str(self.home), "--keyring", str(keyring.resolve()), "--status-fd", "1", str(signature)]
        if data is not None:
            args.append(str(data))
        status = [
            line.split()[1:]
            for line in run(args, check=False).stdout.decode("utf-8", "replace").splitlines()
            if line.startswith("[GNUPG:] ")
        ]
        signers = []
        for words in status:
            if not words:
                continue
            if words[0] in ("BADSIG", "EXPSIG", "EXPKEYSIG", "REVKEYSIG"):
                raise RepoError(f"{signature.name}: gpgv reports {' '.join(words[:2])}")
            if words[0] == "VALIDSIG":
                if len(words) < 11 or words[8] not in STRONG_HASHES:
                    raise RepoError(f"{signature.name}: signature made with a weak hash")
                signers.append(words[10])
        return signers

    def load_signing_key(self, keyfile: Path, primary: str) -> str:
        """Import the online signing subkey. Returns its fingerprint.

        The file must be the archive key with one signing subkey and without
        the primary secret key: that one stays offline.
        """
        self._gpg("--import", str(keyfile))
        records = self.key_records("--list-secret-keys")
        primaries = [record for record in records if record["kind"] == "sec"]
        if len(primaries) != 1 or primaries[0]["fingerprint"] != primary:
            raise RepoError("the signing secret is not a key of the archive keyring")
        if primaries[0]["secret"]:
            raise RepoError("the signing secret holds the primary secret key, which must stay offline")
        subkeys = [r for r in records if r["kind"] == "ssb" and r["secret"] and "s" in r["capabilities"]]
        if len(subkeys) != 1:
            raise RepoError(f"the signing secret must hold exactly one signing subkey, found {len(subkeys)}")
        return subkeys[0]["fingerprint"]

    def sign(self, signer: str, release: bytes) -> tuple[bytes, bytes]:
        """InRelease and Release.gpg for a Release file."""
        source = self.work / "Release"
        inline = self.work / "InRelease"
        detached = self.work / "Release.gpg"
        source.write_bytes(release)
        for path in (inline, detached):
            path.unlink(missing_ok=True)
        common = ("--local-user", f"{signer}!", "--digest-algo", "SHA512", "--armor")
        self._gpg(*common, "--output", str(inline), "--clearsign", str(source))
        self._gpg(*common, "--output", str(detached), "--detach-sign", str(source))
        return inline.read_bytes(), detached.read_bytes()


# --- GitHub release assets ---------------------------------------------------------


def http_open(url: str):
    """The response for a URL, or None for 404. Retries what may pass."""
    last = "no attempt"
    for attempt in range(4):
        if attempt:
            time.sleep(5 * attempt)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "dashmate-apt-publisher"})
            return urllib.request.urlopen(request, timeout=60)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            last = f"HTTP {error.code}"
            if error.code < 500 and error.code != 429:
                break
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last = str(error)
    raise FetchError(f"could not fetch {url}: {last}")


def http_get(url: str, limit: int) -> bytes | None:
    response = http_open(url)
    if response is None:
        return None
    try:
        with response:
            data = response.read(limit + 1)
    except OSError as error:
        raise FetchError(f"could not fetch {url}: {error}") from None
    if len(data) > limit:
        raise RepoError(f"{url} is larger than {limit} bytes")
    return data


def http_download(url: str, target: Path, limit: int) -> tuple[int, dict[str, str]]:
    """Download to a file. Returns its size and its md5, sha1, sha256 and sha512."""
    response = http_open(url)
    if response is None:
        raise RepoError(f"{url} does not exist")
    digests = {name: hashlib.new(name) for name in ("md5", "sha1", "sha256", "sha512")}
    size = 0
    try:
        with response, open(target, "wb") as out:
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > limit:
                    raise RepoError(f"{url} is larger than {limit} bytes")
                out.write(chunk)
                for digest in digests.values():
                    digest.update(chunk)
    except OSError as error:
        raise FetchError(f"could not fetch {url}: {error}") from None
    return size, {name: digest.hexdigest() for name, digest in digests.items()}


# --- the run ---------------------------------------------------------------------------


@dataclass
class Suite:
    name: str
    packages: dict[str, dict[str, Stanza]]
    release: aptrepo.Release | None = None
    changed: bool = False


@dataclass
class Run:
    config: Config
    storage: S3Storage | LocalStorage
    gpg: Gpg
    work: Path
    keyring: Path = field(init=False)
    primary: str = field(init=False)
    maintainers_keyring: Path = field(init=False)
    maintainers: set[str] = field(init=False)
    withdrawn: set[str] = field(default_factory=set)
    suites: dict[str, Suite] = field(default_factory=dict)
    sums_read: dict[str, tuple[dict[str, str], bool] | None] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)

    def prepare_keys(self) -> None:
        self.keyring = self.config.archive_keyring
        if not self.keyring.is_file():
            raise RepoError(f"no archive keyring at {self.keyring}: the repository has no key yet")
        self.primary = self.gpg.public_primary(self.keyring)
        log(f"archive key {self.primary}")

        # One file per maintainer, named for the key's fingerprint, so a key
        # cannot be added without the name saying whose it is.
        self.maintainers = set()
        binary = b""
        for keyfile in sorted(self.config.maintainers.glob("*.asc")):
            dearmored = self.gpg.dearmor(keyfile.read_bytes())
            copy = self.work / "maintainer.gpg"
            copy.write_bytes(dearmored)
            fingerprint = self.gpg.public_primary(copy)
            if fingerprint != keyfile.stem:
                raise RepoError(f"{keyfile.name} holds key {fingerprint}; the file must be named for its key")
            self.maintainers.add(fingerprint)
            binary += dearmored
        self.maintainers_keyring = self.work / "maintainers.gpg"
        self.maintainers_keyring.write_bytes(binary)
        if self.primary in self.maintainers:
            raise RepoError("the archive key is not a maintainer key")
        log(f"maintainer keys: {', '.join(sorted(self.maintainers)) or 'none'}")

    # -- reading what is published --

    def load_suite(self, name: str) -> Suite:
        base = f"dists/{name}"
        fresh = Suite(name=name, packages={arch: {} for arch in ARCHITECTURES})
        release_bytes = self.storage.get(f"{base}/Release")
        if release_bytes is None:
            if self.storage.exists_any(f"{base}/"):
                raise RepoError(f"{name}: files are published but Release is missing; not starting an empty suite over them")
            log(f"{name}: not published yet")
            return fresh
        signature = self.storage.get(f"{base}/Release.gpg")
        if signature is None:
            raise RepoError(f"{name}: Release.gpg is missing")
        release_file = self.work / "published-Release"
        signature_file = self.work / "published-Release.gpg"
        release_file.write_bytes(release_bytes)
        signature_file.write_bytes(signature)
        if self.gpg.valid_signers(self.keyring, signature_file, release_file) != [self.primary]:
            raise RepoError(f"{name}: the published Release is not signed by the archive key")
        release = aptrepo.parse_release(release_bytes)
        if release.suite != name:
            raise RepoError(f"{name}: the published Release is for suite {release.suite}")
        fresh.release = release
        for arch in ARCHITECTURES:
            entry = release.sha256.get(aptrepo.index_path(arch, "Packages"))
            if entry is None:
                raise RepoError(f"{name}: Release does not list Packages for {arch}")
            data = self.storage.get(f"{base}/{aptrepo.by_hash_path(arch, entry[0])}")
            if data is None or sha256_hex(data) != entry[0] or len(data) != entry[1]:
                raise RepoError(f"{name}: Packages for {arch} is missing or is not what Release lists")
            fresh.packages[arch] = aptrepo.parse_packages(data, arch)
        log(f"{name}: {self.describe(fresh)}, signed {aptrepo.format_date(release.date)}")
        return fresh

    @staticmethod
    def describe(suite: Suite) -> str:
        versions = sorted({version for arch in ARCHITECTURES for version in suite.packages[arch]})
        return f"{len(versions)} version(s) [{', '.join(versions)}]" if versions else "empty"

    def published(self, arch: str, sha256: str) -> Stanza | None:
        """A package some suite already carries, by the hash of its file."""
        for suite in self.suites.values():
            for stanza in suite.packages[arch].values():
                if stanza.sha256 == sha256:
                    return stanza
        return None

    # -- reading a release --

    def release_sums(self, tag: aptrepo.Tag, request: aptrepo.Request | None = None) -> tuple[dict[str, str], bool] | None:
        """SHA256SUMS of a release, and whether a maintainer signed it. None if it has none.

        With `request`, the file must be the one the request names. A release
        is read once in a run: the requested release is the first one read,
        and nothing later in the run sees another SHA256SUMS for it.
        """
        if tag.name not in self.sums_read:
            self.sums_read[tag.name] = self.read_release_sums(tag, request)
        return self.sums_read[tag.name]

    def read_release_sums(self, tag: aptrepo.Tag, request: aptrepo.Request | None) -> tuple[dict[str, str], bool] | None:
        base = f"{self.config.release_base_url}/{tag.name}"
        sums = http_get(f"{base}/SHA256SUMS", SUMS_LIMIT)
        if sums is None:
            return None
        if request is not None:
            aptrepo.check_sums_digest(request, sums)
            log(f"{tag.name}: SHA256SUMS is the file the request names, sha256 {request.sums_sha256}")
        signed = False
        signature = http_get(f"{base}/SHA256SUMS.asc", SUMS_LIMIT) if self.maintainers else None
        if signature is not None:
            sums_file = self.work / "SHA256SUMS"
            signature_file = self.work / "SHA256SUMS.asc"
            sums_file.write_bytes(sums)
            signature_file.write_bytes(signature)
            signers = self.gpg.valid_signers(self.maintainers_keyring, signature_file, sums_file)
            signed = any(signer in self.maintainers for signer in signers)
            if not signed:
                log(f"{tag.name}: SHA256SUMS.asc is not by a maintainer key this repository accepts")
        return aptrepo.parse_sha256sums(sums), signed

    def add_release(self, request: aptrepo.Request) -> None:
        tag = request.tag
        found = self.release_sums(tag, request)
        if found is None:
            raise RepoError(f"{tag.name}: the release has no SHA256SUMS, so its packages cannot be checked")
        sums, signed = found
        targets = aptrepo.suites_for(tag, signed)
        log(f"{tag.name}: {'signed by a maintainer' if signed else 'not signed'}; goes to {', '.join(targets)}")
        if tag.final and not signed:
            log(f"{tag.name}: stays out of stable until a maintainer signs SHA256SUMS; a later run moves it")
        stanzas = {}
        for arch, (asset, sha256) in aptrepo.release_debs(sums, tag).items():
            stanza = self.published(arch, sha256)
            if stanza is not None:
                aptrepo.check_deb_version(tag, stanza.version)
                self.refuse_withdrawn(stanza)
            else:
                stanza = self.fetch_deb(tag, arch, asset, sha256)
            stanzas[arch] = stanza
        for name in targets:
            for arch, stanza in stanzas.items():
                if aptrepo.add_stanza(self.suites[name].packages[arch], stanza):
                    self.suites[name].changed = True
                    log(f"{name}: + {arch} {stanza.version}")

    def fetch_deb(self, tag: aptrepo.Tag, arch: str, asset: str, sha256: str) -> Stanza:
        target = self.work / "package.deb"
        size, digests = http_download(f"{self.config.release_base_url}/{tag.name}/{asset}", target, DEB_LIMIT)
        if digests["sha256"] != sha256:
            raise RepoError(f"{asset} has sha256 {digests['sha256']}, SHA256SUMS says {sha256}")
        try:
            control = run(["dpkg-deb", "--field", str(target)]).stdout.decode("utf-8")
        except UnicodeDecodeError:
            raise RepoError(f"{asset}: the control file is not UTF-8") from None
        stanza = aptrepo.make_stanza(control, arch, tag, size, digests)
        self.refuse_withdrawn(stanza)
        # Refused here, before the pool is touched, when a suite already
        # carries this version with other bytes.
        for suite in self.suites.values():
            aptrepo.add_stanza(dict(suite.packages[arch]), stanza)
        written = self.storage.put_file_once(stanza.fields["filename"], target, sha256, DEB, IMMUTABLE)
        log(f"pool: {stanza.fields['filename']} {'uploaded' if written else 'already there'} ({size} bytes)")
        target.unlink()
        return stanza

    def promote_signed_finals(self) -> None:
        """Final releases wait in `testing` until a maintainer signs them. Move the signed ones."""
        testing, stable = self.suites["testing"], self.suites["stable"]
        waiting = sorted({
            version
            for arch in ARCHITECTURES
            for version in testing.packages[arch]
            if aptrepo.final_tag_of(version) and version not in stable.packages[arch]
        })
        for version in waiting:
            tag = aptrepo.parse_tag(aptrepo.final_tag_of(version))
            try:
                found = self.release_sums(tag)
                if found is None or not found[1]:
                    log(f"stable: {version} waits for a maintainer's signature on {tag.name}")
                    continue
                debs = aptrepo.release_debs(found[0], tag)
                stanzas = {arch: testing.packages[arch].get(version) for arch in ARCHITECTURES}
                if any(s is None or debs[arch][1] != s.sha256 for arch, s in stanzas.items()):
                    log(f"stable: {version} is not what the signed SHA256SUMS of {tag.name} lists; left in testing")
                    continue
                for arch, stanza in stanzas.items():
                    if aptrepo.add_stanza(stable.packages[arch], stanza):
                        stable.changed = True
                        log(f"stable: + {arch} {version} (signed since)")
            except FetchError as error:
                log(f"stable: {version} not checked this time: {error}")
            except RepoError as error:
                self.problems.append(f"{tag.name}: {error}")

    def read_withdrawn(self) -> None:
        """Versions listed in withdrawn.txt are in no suite and cannot come back."""
        if not self.config.withdrawn.is_file():
            return
        for line in self.config.withdrawn.read_text(encoding="utf-8").splitlines():
            version = line.split("#", 1)[0].strip()
            if version:
                self.withdrawn.add(version)

    def refuse_withdrawn(self, stanza: Stanza) -> None:
        if stanza.version in self.withdrawn:
            raise RepoError(f"{stanza.version} is withdrawn (withdrawn.txt); publish a higher version instead")

    def drop_withdrawn(self) -> None:
        """Take withdrawn versions out of every suite. Their pool files stay."""
        for suite in self.suites.values():
            for arch in ARCHITECTURES:
                for version in sorted(self.withdrawn & set(suite.packages[arch])):
                    del suite.packages[arch][version]
                    suite.changed = True
                    log(f"{suite.name}: - {arch} {version} (withdrawn)")

    # -- writing --

    def publish_suite(self, suite: Suite, signer: str, now: datetime) -> bool:
        base = f"dists/{suite.name}"
        files: dict[str, bytes] = {}
        for arch in ARCHITECTURES:
            packages = aptrepo.render_packages(suite.packages[arch])
            for name, data in aptrepo.index_files(packages).items():
                files[aptrepo.index_path(arch, name)] = data
        if suite.release is not None and not suite.changed:
            same = all(
                suite.release.sha256[aptrepo.index_path(arch, "Packages")][0]
                == sha256_hex(files[aptrepo.index_path(arch, "Packages")])
                for arch in ARCHITECTURES
            )
            if not same:
                raise RepoError(f"{suite.name}: the index read back does not render to itself")
            if now - suite.release.date < self.config.min_resign_age:
                log(f"{suite.name}: unchanged and signed recently; left as it is")
                return False

        release = aptrepo.render_release(suite.name, files, now, self.config.valid_days)
        inline, detached = self.gpg.sign(signer, release)

        # What goes out must verify with the keyring operators have.
        release_file = self.work / "Release"
        inline_file = self.work / "InRelease"
        detached_file = self.work / "Release.gpg"
        if self.gpg.valid_signers(self.keyring, detached_file, release_file) != [self.primary]:
            raise RepoError("the new Release.gpg does not verify with the archive keyring")
        if self.gpg.valid_signers(self.keyring, inline_file) != [self.primary]:
            raise RepoError("the new InRelease does not verify with the archive keyring")

        # Indexes first, under names that never change content, then the
        # files that point at them. InRelease goes last: until it is replaced,
        # hosts keep reading the previous, complete state.
        for path, data in files.items():
            arch = path.split("/")[1].removeprefix("binary-")
            self.storage.put(f"{base}/{aptrepo.by_hash_path(arch, sha256_hex(data))}", data, BINARY, IMMUTABLE)
        for path, data in files.items():
            self.storage.put(f"{base}/{path}", data, BINARY, SHORT)
        self.storage.put(f"{base}/Release", release, TEXT, SHORT)
        self.storage.put(f"{base}/Release.gpg", detached, TEXT, SHORT)
        self.storage.put(f"{base}/InRelease", inline, TEXT, SHORT)
        log(f"{suite.name}: published, {self.describe(suite)}, valid until "
            f"{aptrepo.format_date(now + timedelta(days=self.config.valid_days))}")
        return True

    def load_signing_key(self) -> str:
        keyfile = self.work / "signing-key"
        if self.config.signing_key_file:
            shutil.copyfile(self.config.signing_key_file, keyfile)
        else:
            proc = run([
                "aws", "secretsmanager", "get-secret-value", "--secret-id", self.config.signing_secret_id,
                "--query", "SecretBinary", "--output", "text",
            ])
            keyfile.write_bytes(base64.b64decode(proc.stdout.strip(), validate=True))
        try:
            return self.gpg.load_signing_key(keyfile, self.primary)
        finally:
            keyfile.unlink()

    def execute(self) -> None:
        config = self.config
        # Refused before anything is read, so a bad request costs nothing.
        request = aptrepo.parse_request(config.release_tag, config.sums_sha256)
        self.prepare_keys()
        self.read_withdrawn()
        for name in SUITES:
            self.suites[name] = self.load_suite(name)
        self.drop_withdrawn()

        # Everything that reads what others wrote happens before the signing
        # key is fetched.
        if request is not None:
            self.add_release(request)
        self.promote_signed_finals()

        signer = self.load_signing_key()
        now = datetime.now(timezone.utc).replace(microsecond=0)
        for name in SUITES:
            self.publish_suite(self.suites[name], signer, now)
        self.storage.put("dashmate-archive-keyring.gpg", self.keyring.read_bytes(), "application/pgp-keys", "public, max-age=300")


def main() -> int:
    try:
        config = Config.from_env()
    except (RepoError, ValueError) as error:
        log(f"REFUSED: {error}")
        return 2
    with tempfile.TemporaryDirectory(prefix="apt-") as directory:
        work = Path(directory)
        storage = (
            S3Storage(config.bucket, config.prefix, work) if config.bucket
            else LocalStorage(config.directory, config.prefix)
        )
        job = Run(config=config, storage=storage, gpg=Gpg(work), work=work)
        try:
            job.execute()
        except RepoError as error:
            log(f"REFUSED: {error}")
            return 2
        except Exception:  # a bug, or a tool that answered in a way nobody planned for
            log(f"REFUSED: unexpected error\n{traceback.format_exc()}")
            return 2
        finally:
            job.gpg.close()
    for problem in job.problems:
        log(f"NEEDS A PERSON: {problem}")
    return 1 if job.problems else 0


if __name__ == "__main__":
    sys.exit(main())
