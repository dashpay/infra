"""The rules of the dashmate apt repository, as pure functions.

Nothing here touches the network, AWS, gpg or dpkg, so every rule is covered
by tests/test_aptrepo.py. publish.py does the I/O.
"""

from __future__ import annotations

import gzip
import hashlib
import lzma
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

PACKAGE = "dashmate"
COMPONENT = "main"
ARCHITECTURES = ("amd64", "arm64")

# A suite also carries everything the suites before it carry, so a host that
# follows `testing` or `dev` still reaches every final release.
SUITES = ("stable", "testing", "dev")


class RepoError(Exception):
    """The input is not something this repository publishes."""


class NotPublished(RepoError):
    """A well-formed request for a kind of release this repository leaves out.

    Nothing is wrong with the release or the request: the answer is "skipped".
    """


# --- release tags and Debian versions -------------------------------------
#
# The same grammar as packages/dashmate/scripts/deb-version.mjs in
# dashpay/platform, which turns a tag into the version inside the deb.

_NUMERIC = r"(?:0|[1-9][0-9]*)"
_PRERELEASE_ID = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z][0-9A-Za-z]*)"
_TAG = re.compile(
    rf"v({_NUMERIC}\.{_NUMERIC}\.{_NUMERIC})"
    rf"(?:-({_PRERELEASE_ID}(?:\.{_PRERELEASE_ID})*))?"
)

# Which suites a prerelease goes to, by the first identifier of its
# prerelease part. Anything else (alpha, pr, hotfix) is not published.
_PRERELEASE_SUITES = {
    "dev": ("dev",),
    "beta": ("testing", "dev"),
    "rc": ("testing", "dev"),
}


@dataclass(frozen=True)
class Tag:
    name: str
    release: str
    prerelease: str | None

    @property
    def label(self) -> str | None:
        return None if self.prerelease is None else self.prerelease.split(".")[0]

    @property
    def final(self) -> bool:
        return self.prerelease is None

    @property
    def upstream(self) -> str:
        """The upstream part of the Debian version built from this tag."""
        if self.prerelease is None:
            return self.release
        # `~` sorts below the end of the string, and `~~` below `~`: dev
        # builds stay below every beta and rc of the same release.
        tilde = "~~" if self.label == "dev" else "~"
        return f"{self.release}{tilde}{self.prerelease}"


def parse_tag(name: str) -> Tag:
    match = _TAG.fullmatch(name)
    if match is None:
        raise RepoError(f"{name!r} is not a release tag such as v5.1.0 or v5.1.0-rc.1")
    return Tag(name=name, release=match.group(1), prerelease=match.group(2))


def suites_for(tag: Tag, signed: bool) -> tuple[str, ...]:
    """The suites a release belongs in.

    `signed` says whether a maintainer signed the release's SHA256SUMS. Only
    a signed final release reaches `stable`.
    """
    if tag.final:
        return ("stable", "testing", "dev") if signed else ("testing", "dev")
    try:
        return _PRERELEASE_SUITES[tag.label]
    except KeyError:
        raise NotPublished(
            f"{tag.name}: prereleases named {tag.label!r} are not published; "
            f"only {', '.join(sorted(_PRERELEASE_SUITES))}"
        ) from None


# --- what a run is asked to do -----------------------------------------------

_SHA256 = re.compile(r"[0-9a-f]{64}")


@dataclass(frozen=True)
class Request:
    """A release to publish, and the SHA256SUMS it is to be published from."""

    tag: Tag
    sums_sha256: str


def parse_request(tag: str, sums_sha256: str) -> Request | None:
    """What RELEASE_TAG and SHA256SUMS_SHA256 ask for. None: only refresh.

    A release is named together with the sha256 of the SHA256SUMS that the
    release workflow checked and attached. The release's assets can be
    replaced after that check, so the tag alone does not say which packages
    were meant; the digest does. A tag without it is refused.
    """
    if not tag:
        if sums_sha256:
            raise RepoError("a sha256 of SHA256SUMS was given without a release tag")
        return None
    parsed = parse_tag(tag)
    if not sums_sha256:
        raise RepoError(
            f"{parsed.name}: the request does not carry sha256sums_sha256, the sha256 of the "
            f"SHA256SUMS it was made for; a release is published only from that file"
        )
    if _SHA256.fullmatch(sums_sha256) is None:
        raise RepoError(
            f"{parsed.name}: sha256sums_sha256 must be 64 lowercase hex digits, got {sums_sha256[:80]!r}"
        )
    suites_for(parsed, False)  # NotPublished for a kind of prerelease that is left out
    return Request(tag=parsed, sums_sha256=sums_sha256)


def check_sums_digest(request: Request, sums: bytes) -> None:
    """Refuse a SHA256SUMS that is not the file the request was made for."""
    found = hashlib.sha256(sums).hexdigest()
    if found != request.sums_sha256:
        raise RepoError(
            f"{request.tag.name}: the release's SHA256SUMS has sha256 {found}, and the request was "
            f"made for {request.sums_sha256}. The file was replaced after the request's run checked "
            f"it, or the request names another one"
        )


def check_deb_version(tag: Tag, version: str) -> None:
    """Refuse a deb whose version is not the one its tag stands for."""
    pattern = rf"(?:[1-9][0-9]*:)?{re.escape(tag.upstream)}-[1-9][0-9]*"
    if re.fullmatch(pattern, version) is None:
        raise RepoError(
            f"{tag.name}: the deb says Version {version!r}, expected {tag.upstream}-<revision>"
        )


def version_without_epoch(version: str) -> str:
    return version.split(":", 1)[1] if ":" in version else version


def pool_key(version: str, arch: str) -> str:
    """Where a deb lives, relative to the repository root. Never reused."""
    return f"pool/{COMPONENT}/d/{PACKAGE}/{PACKAGE}_{version_without_epoch(version)}_{arch}.deb"


def final_tag_of(version: str) -> str | None:
    """The tag a final release's deb came from, or None for a prerelease."""
    match = re.fullmatch(
        rf"(?:[1-9][0-9]*:)?({_NUMERIC}\.{_NUMERIC}\.{_NUMERIC})-[1-9][0-9]*", version
    )
    return None if match is None else f"v{match.group(1)}"


# --- SHA256SUMS ------------------------------------------------------------

_SUMS_LINE = re.compile(r"([0-9a-f]{64})  (dashmate[A-Za-z0-9._-]*)")


def parse_sha256sums(data: bytes) -> dict[str, str]:
    """name -> sha256, for a SHA256SUMS as the release workflow writes it."""
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise RepoError("SHA256SUMS is not ASCII") from None
    if not text.endswith("\n"):
        raise RepoError("SHA256SUMS does not end with a newline")
    sums: dict[str, str] = {}
    for line in text[:-1].split("\n"):
        match = _SUMS_LINE.fullmatch(line)
        if match is None:
            raise RepoError(f"SHA256SUMS has a line that is not '<sha256>  dashmate...': {line!r}")
        digest, name = match.groups()
        if name in sums:
            raise RepoError(f"SHA256SUMS lists {name} twice")
        sums[name] = digest
    return sums


def release_debs(sums: dict[str, str], tag: Tag) -> dict[str, tuple[str, str]]:
    """arch -> (asset name, sha256): exactly one deb of this tag per architecture.

    In an asset's name every run of `~` is a `.`, because GitHub rewrites `~`.
    """
    name_version = re.sub(r"~+", ".", tag.upstream)
    debs: dict[str, tuple[str, str]] = {}
    for arch in ARCHITECTURES:
        pattern = rf"{PACKAGE}_{re.escape(name_version)}-[1-9][0-9]*_{arch}\.deb"
        found = sorted(name for name in sums if re.fullmatch(pattern, name))
        if len(found) != 1:
            raise RepoError(
                f"{tag.name}: SHA256SUMS must list exactly one {arch} deb of this version, "
                f"found {found or 'none'}"
            )
        debs[arch] = (found[0], sums[found[0]])
    return debs


# --- control paragraphs and Packages ---------------------------------------

_FIELD = re.compile(r"([A-Za-z0-9][A-Za-z0-9_-]*):[ \t]*(.*)")
_VERSION = re.compile(r"(?:[1-9][0-9]*:)?[0-9][0-9A-Za-z.+~]*-[1-9][0-9]*")
_GENERATED_FIELDS = ("filename", "size", "md5sum", "sha1", "sha256", "sha512")


@dataclass(frozen=True)
class Stanza:
    """One package in a Packages file."""

    text: str  # as written to Packages: every line ends with \n, none is blank
    fields: dict[str, str]  # lower-cased name -> value

    @property
    def version(self) -> str:
        return self.fields["version"]

    @property
    def sha256(self) -> str:
        return self.fields["sha256"]


def parse_paragraph(text: str) -> dict[str, str]:
    """Fields of one deb822 paragraph, by lower-cased name."""
    for char in text:
        if char != "\n" and char != "\t" and (ord(char) < 0x20 or ord(char) == 0x7F):
            raise RepoError(f"control character {char!r} in a control paragraph")
    fields: dict[str, str] = {}
    current = None
    for line in text.split("\n"):
        if line == "":
            raise RepoError("blank line inside a control paragraph")
        if line[0] in " \t":
            if current is None:
                raise RepoError("a control paragraph starts with a continuation line")
            fields[current] += "\n" + line
            continue
        match = _FIELD.fullmatch(line)
        if match is None:
            raise RepoError(f"not a control field: {line!r}")
        current = match.group(1).lower()
        if current in fields:
            raise RepoError(f"field {match.group(1)} appears twice")
        fields[current] = match.group(2)
    return fields


def _require(fields: dict[str, str], name: str) -> str:
    value = fields.get(name)
    if not value or "\n" in value:
        raise RepoError(f"missing or multi-line field {name}")
    return value


def _check_stanza(fields: dict[str, str], arch: str) -> None:
    if _require(fields, "package") != PACKAGE:
        raise RepoError(f"Package is {fields['package']!r}, not {PACKAGE}")
    if _require(fields, "architecture") != arch:
        raise RepoError(f"Architecture is {fields['architecture']!r}, not {arch}")
    version = _require(fields, "version")
    if _VERSION.fullmatch(version) is None:
        raise RepoError(f"not a version this repository publishes: {version!r}")
    if _require(fields, "filename") != pool_key(version, arch):
        raise RepoError(f"Filename {fields['filename']!r} is not {pool_key(version, arch)}")
    if re.fullmatch(r"[0-9a-f]{64}", _require(fields, "sha256")) is None:
        raise RepoError("SHA256 is not a sha256")
    if re.fullmatch(r"[1-9][0-9]*", _require(fields, "size")) is None:
        raise RepoError("Size is not a number")


def make_stanza(control: str, arch: str, tag: Tag, size: int, digests: dict[str, str]) -> Stanza:
    """The Packages entry for a deb, from its control file and its hashes.

    `digests` maps md5, sha1, sha256 and sha512 to hex digests of the file.
    """
    control = control.strip("\n")
    fields = parse_paragraph(control)
    for name in _GENERATED_FIELDS:
        if name in fields:
            raise RepoError(f"the deb's control file sets {name}, which the repository writes")
    version = _require(fields, "version")
    check_deb_version(tag, version)
    text = (
        f"{control}\n"
        f"Filename: {pool_key(version, arch)}\n"
        f"Size: {size}\n"
        f"MD5sum: {digests['md5']}\n"
        f"SHA1: {digests['sha1']}\n"
        f"SHA256: {digests['sha256']}\n"
        f"SHA512: {digests['sha512']}\n"
    )
    fields = parse_paragraph(text[:-1])
    _check_stanza(fields, arch)
    return Stanza(text=text, fields=fields)


def parse_packages(data: bytes, arch: str) -> dict[str, Stanza]:
    """version -> stanza, for a Packages file this publisher wrote."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise RepoError("Packages is not UTF-8") from None
    packages: dict[str, Stanza] = {}
    for paragraph in re.split(r"\n{2,}", text.strip("\n")):
        if paragraph == "":
            continue
        fields = parse_paragraph(paragraph)
        _check_stanza(fields, arch)
        if fields["version"] in packages:
            raise RepoError(f"Packages lists {fields['version']} twice")
        packages[fields["version"]] = Stanza(text=paragraph + "\n", fields=fields)
    return packages


def render_packages(packages: dict[str, Stanza]) -> bytes:
    return "\n".join(packages[version].text for version in sorted(packages)).encode("utf-8")


def add_stanza(packages: dict[str, Stanza], stanza: Stanza) -> bool:
    """Add a package to a suite. True if the suite changed.

    A version is published once: the same version with other bytes is refused.
    """
    present = packages.get(stanza.version)
    if present is None:
        packages[stanza.version] = stanza
        return True
    if present.sha256 != stanza.sha256:
        raise RepoError(
            f"{stanza.fields['architecture']} {stanza.version} is already published with sha256 "
            f"{present.sha256}; the release now has {stanza.sha256}. Rebuilds need a new revision."
        )
    return False


def index_files(packages: bytes) -> dict[str, bytes]:
    """The index of one architecture, in the three forms apt asks for."""
    return {
        "Packages": packages,
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.xz": lzma.compress(packages),
    }


# --- Release -----------------------------------------------------------------

_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
_DATE = re.compile(r"[A-Z][a-z]{2}, ([0-9]{2}) ([A-Z][a-z]{2}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) UTC")


def format_date(moment: datetime) -> str:
    moment = moment.astimezone(timezone.utc)
    return (
        f"{_DAYS[moment.weekday()]}, {moment.day:02d} {_MONTHS[moment.month - 1]} {moment.year} "
        f"{moment.hour:02d}:{moment.minute:02d}:{moment.second:02d} UTC"
    )


def parse_date(text: str) -> datetime:
    match = _DATE.fullmatch(text)
    if match is None or match.group(2) not in _MONTHS:
        raise RepoError(f"not a Release date: {text!r}")
    day, month, year, hour, minute, second = match.groups()
    try:
        return datetime(
            int(year), _MONTHS.index(month) + 1, int(day), int(hour), int(minute), int(second),
            tzinfo=timezone.utc,
        )
    except ValueError:
        raise RepoError(f"not a Release date: {text!r}") from None


@dataclass(frozen=True)
class Release:
    date: datetime
    valid_until: datetime
    suite: str
    sha256: dict[str, tuple[str, int]]  # path below dists/<suite>/ -> (sha256, size)


def render_release(suite: str, files: dict[str, bytes], now: datetime, valid_days: int) -> bytes:
    """The Release file of a suite. `files` maps paths below dists/<suite>/ to content."""
    if suite not in SUITES:
        raise RepoError(f"unknown suite {suite!r}")
    lines = [
        "Origin: Dash Core Group",
        "Label: dashmate",
        f"Suite: {suite}",
        f"Codename: {suite}",
        f"Date: {format_date(now)}",
        # Without this a signed snapshot is valid for ever, and whoever sits
        # between a host and the repository can hold the host on an old one.
        f"Valid-Until: {format_date(now + timedelta(days=valid_days))}",
        f"Architectures: {' '.join(ARCHITECTURES)}",
        f"Components: {COMPONENT}",
        f"Description: dashmate, the Dash Platform node manager ({suite})",
        # apt then fetches each index by its hash, from a path whose content
        # never changes, so a cache cannot pair a new Release with an old index.
        "Acquire-By-Hash: yes",
        "SHA256:",
    ]
    for path in sorted(files):
        lines.append(f" {hashlib.sha256(files[path]).hexdigest()} {len(files[path]):>16} {path}")
    return ("\n".join(lines) + "\n").encode("ascii")


def parse_release(data: bytes) -> Release:
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise RepoError("Release is not ASCII") from None
    fields = parse_paragraph(text.strip("\n"))
    sha256: dict[str, tuple[str, int]] = {}
    first, *entries = fields.get("sha256", "missing").split("\n")
    if first != "":
        raise RepoError("Release has no SHA256 section")
    for entry in entries:
        parts = entry.split()
        if len(parts) != 3 or re.fullmatch(r"[0-9a-f]{64}", parts[0]) is None or not parts[1].isdigit():
            raise RepoError(f"not a SHA256 entry: {entry!r}")
        sha256[parts[2]] = (parts[0], int(parts[1]))
    return Release(
        date=parse_date(_require(fields, "date")),
        valid_until=parse_date(_require(fields, "valid-until")),
        suite=_require(fields, "suite"),
        sha256=sha256,
    )


def index_path(arch: str, name: str) -> str:
    return f"{COMPONENT}/binary-{arch}/{name}"


def by_hash_path(arch: str, sha256: str) -> str:
    return f"{COMPONENT}/binary-{arch}/by-hash/SHA256/{sha256}"
