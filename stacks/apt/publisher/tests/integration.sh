#!/usr/bin/env bash
# End-to-end test of the publisher, with throwaway keys and a real apt client.
#
# For a disposable Ubuntu machine with sudo: it installs test packages named
# dashmate, writes /etc/apt/sources.list.d/dashmate.sources and a keyring in
# /etc/apt/keyrings, the paths the dashmate package owns. Never run it on a
# host that runs dashmate.
#
#   bash stacks/apt/publisher/tests/integration.sh
#   REAL=1 bash ...   also publishes a real release of dashpay/platform (190 MB)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
REPO="$W/repo"
REL="$W/releases"
mkdir -p "$REPO" "$REL" "$W/keyring" "$W/maintainers"
: > "$W/withdrawn.txt"
export GNUPGHOME="$W/gnupg"
mkdir -m 700 "$GNUPGHOME"

ok() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; [ -f "$W/out" ] && sed 's/^/       /' "$W/out"; exit 1; }

sudo apt-get install -y -qq faketime > /dev/null
python3 -m http.server 8081 --bind 127.0.0.1 --directory "$REPO" > /dev/null 2>&1 &
python3 -m http.server 8082 --bind 127.0.0.1 --directory "$REL" > /dev/null 2>&1 &
trap 'kill $(jobs -p) 2> /dev/null || true' EXIT

# --- keys ----------------------------------------------------------------------

new_key() { # user id, usage -> fingerprint
  gpg --batch --quiet --passphrase '' --quick-generate-key "$1" ed25519 "$2" 1y
  gpg --list-keys --with-colons "$1" | awk -F: '$1 == "fpr" { print $10; exit }'
}
secret() { gpg --batch --pinentry-mode loopback --passphrase '' "$@"; }

ARCHIVE="$(new_key 'Dashmate test archive <archive@example.invalid>' cert)"
gpg --batch --quiet --passphrase '' --quick-add-key "$ARCHIVE" ed25519 sign 1y
gpg --batch --quiet --passphrase '' --quick-add-key "$ARCHIVE" ed25519 sign 1y
mapfile -t SUBKEYS < <(gpg --list-keys --with-colons "$ARCHIVE" | awk -F: '$1 == "sub" { s = 1; next } s && $1 == "fpr" { print $10; s = 0 }')
[ "${#SUBKEYS[@]}" = 2 ] || fail "expected two signing subkeys"
gpg --export "$ARCHIVE" > "$W/keyring/dashmate-archive-keyring.gpg"
secret --export-secret-subkeys "${SUBKEYS[0]}!" > "$W/signing.key"
secret --export-secret-subkeys "${SUBKEYS[1]}!" > "$W/standby.key"
secret --export-secret-keys "$ARCHIVE" > "$W/whole.key"

MAINTAINER="$(new_key 'Test maintainer <maintainer@example.invalid>' sign)"
OUTSIDER="$(new_key 'Somebody else <outsider@example.invalid>' sign)"
gpg --armor --export "$MAINTAINER" > "$W/maintainers/$MAINTAINER.asc"

# --- helpers ---------------------------------------------------------------------

make_release() { # tag, Debian version, [content marker]
  local tag="$1" version="$2" marker="${3:-first build}" arch root
  local name_version dir="$REL/$1"
  name_version="$(echo "$version" | sed -E 's/~+/./g')"
  rm -rf "$dir"
  mkdir -p "$dir"
  for arch in amd64 arm64; do
    root="$W/deb"
    rm -rf "$root"
    mkdir -p "$root/DEBIAN" "$root/usr/share/dashmate-test"
    echo "$version $arch $marker" > "$root/usr/share/dashmate-test/version"
    printf '%s\n' "Package: dashmate" "Version: $version" "Section: misc" "Priority: optional" \
      "Architecture: $arch" "Maintainer: Dash Core Group <dev@dash.org>" \
      "Description: test package" " built for the publisher's integration test" > "$root/DEBIAN/control"
    dpkg-deb --root-owner-group --build "$root" "$dir/dashmate_${name_version}_${arch}.deb" > /dev/null
  done
  echo "not a deb" > "$dir/dashmate-$tag-0123abcdef-linux-x64.tar.gz"
  (cd "$dir" && sha256sum dashmate* | sort -k2,2 > SHA256SUMS)
}

sign_release() { # tag, key
  rm -f "$REL/$1/SHA256SUMS.asc"
  gpg --batch --quiet --local-user "$2" --armor --detach-sign --output "$REL/$1/SHA256SUMS.asc" "$REL/$1/SHA256SUMS"
}

sums_of() { # tag -> the sha256 of the SHA256SUMS its release has now
  sha256sum < "$REL/$1/SHA256SUMS" | cut -d ' ' -f 1
}

publish() { # [tag]. KEY, AGE, BASE, KEYRING, TO and SUMS change one input.
  # A request names its release's SHA256SUMS by sha256. Unless SUMS says
  # otherwise, that is the file the release has now.
  local sums=""
  if [ -n "${SUMS+set}" ]; then
    sums="$SUMS"
  elif [ -n "${1:-}" ]; then
    sums="$(printf '0%.0s' {1..64})"
    [ ! -f "$REL/$1/SHA256SUMS" ] || sums="$(sums_of "$1")"
  fi
  REPO_DIR="${TO:-$REPO}" REPO_PREFIX=dashmate SIGNING_KEY_FILE="${KEY:-$W/signing.key}" \
    ARCHIVE_KEYRING="${KEYRING:-$W/keyring/dashmate-archive-keyring.gpg}" MAINTAINERS_DIR="$W/maintainers" \
    WITHDRAWN_FILE="$W/withdrawn.txt" RELEASE_BASE_URL="${BASE:-http://127.0.0.1:8082}" \
    MIN_RESIGN_AGE_HOURS="${AGE:-0}" RELEASE_TAG="${1:-}" SHA256SUMS_SHA256="$sums" python3 "$HERE/publish.py"
}

snapshot() { # the sha256 of every file of the repository, as one sha256
  (cd "${TO:-$REPO}" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum
}

expect() { # exit status, text the output must contain, command...
  local want="$1" text="$2" got=0
  shift 2
  "$@" > "$W/out" 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "exit status $got, expected $want: $*"
  grep -qF -- "$text" "$W/out" || fail "output lacks '$text': $*"
}

carries() { # suite, versions expected in both architectures
  local arch got
  for arch in amd64 arm64; do
    got="$(awk '/^Version:/ { print $2 }' "${TO:-$REPO}/dashmate/dists/$1/main/binary-$arch/Packages" | sort | paste -sd ' ' -)"
    [ "$got" = "$2" ] || fail "$1/$arch carries [$got], expected [$2]"
  done
  ok "$1 carries [$2]"
}

use_suite() {
  printf '%s\n' "Types: deb" "URIs: http://127.0.0.1:8081/dashmate" "Suites: $1" "Components: main" \
    "Architectures: amd64 arm64" "Signed-By: /etc/apt/keyrings/dashmate-archive-keyring.gpg" |
    sudo tee /etc/apt/sources.list.d/dashmate.sources > /dev/null
}
apt_update() { # any failure is an error, and only our source is read
  sudo "$@" apt-get update -o Dir::Etc::sourcelist=sources.list.d/dashmate.sources \
    -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 -o APT::Update::Error-Mode=any
}
installed() { dpkg-query -W -f '${Version}' dashmate; }

# --- nothing is published without the right keys --------------------------------

KEYRING="$W/none.gpg" expect 2 "no archive keyring" publish
KEY="$W/whole.key" expect 2 "must stay offline" publish
[ ! -e "$REPO/dashmate" ] || fail "a refused run wrote something"
ok "refused without a keyring, and with the primary secret key"

expect 2 "not a release tag" publish 'v5.1.0;id'
make_release v5.1.0-alpha.1 '5.1.0~alpha.1-1'
expect 3 "SKIPPED: v5.1.0-alpha.1: prereleases named 'alpha' are not published" publish v5.1.0-alpha.1
expect 2 "has no SHA256SUMS" publish v9.9.9
make_release v5.1.0-rc.1 '5.1.0~rc.1-1'
SUMS="" expect 2 "does not carry sha256sums_sha256" publish v5.1.0-rc.1
SUMS="$(sums_of v5.1.0-rc.1 | tr a-f A-F)" expect 2 "64 lowercase hex digits" publish v5.1.0-rc.1
SUMS="$(sums_of v5.1.0-rc.1)" expect 2 "without a release tag" publish
[ ! -e "$REPO/dashmate" ] || fail "a refused run wrote something"
ok "refused a bad tag, a release that does not exist, and a tag without the sha256 of its SHA256SUMS; skipped an alpha"

# --- empty suites, signed, from the first run -----------------------------------

expect 0 "stable: published, empty" publish
carries stable ""
sudo install -D -m 0644 "$W/keyring/dashmate-archive-keyring.gpg" /etc/apt/keyrings/dashmate-archive-keyring.gpg
use_suite stable
expect 0 "" apt_update
ok "apt-get update accepts the signed, empty stable"

# --- releases go to the suites they belong in -----------------------------------

make_release v5.1.0-dev.4 '5.1.0~~dev.4-1'
expect 0 "dev: + amd64 5.1.0~~dev.4-1" publish v5.1.0-dev.4
sign_release v5.1.0-rc.1 "$MAINTAINER"
expect 0 "PUBLISHED: v5.1.0-rc.1 is in testing, dev as 5.1.0~rc.1-1" publish v5.1.0-rc.1
carries stable ""
carries testing "5.1.0~rc.1-1"
carries dev "5.1.0~rc.1-1 5.1.0~~dev.4-1"

make_release v5.1.0 '5.1.0-1'
expect 0 "stays out of stable" publish v5.1.0
carries stable ""
carries testing "5.1.0-1 5.1.0~rc.1-1"

sign_release v5.1.0 "$OUTSIDER"
expect 0 "waits for a maintainer's signature" publish
carries stable ""
ok "a signature by a key that is not a maintainer's opens nothing"

sign_release v5.1.0 "$MAINTAINER"
expect 0 "stable: + amd64 5.1.0-1 (signed since)" publish
carries stable "5.1.0-1"

# --- a release is published only from the SHA256SUMS its request names ---------

make_release v5.1.1-rc.1 '5.1.1~rc.1-1'
checked="$(sums_of v5.1.1-rc.1)"
make_release v5.1.1-rc.1 '5.1.1~rc.1-1' "replaced after the check"
sign_release v5.1.1-rc.1 "$MAINTAINER"
before="$(snapshot)"
SUMS="$checked" expect 2 "and the request was made for $checked" publish v5.1.1-rc.1
SUMS="" expect 2 "does not carry sha256sums_sha256" publish v5.1.1-rc.1
[ "$(snapshot)" = "$before" ] || fail "a refused request changed the repository"
ok "refused a release whose SHA256SUMS is not the one its request names, and wrote nothing"
expect 0 "testing: + amd64 5.1.1~rc.1-1" publish v5.1.1-rc.1
carries stable "5.1.0-1"
carries testing "5.1.0-1 5.1.0~rc.1-1 5.1.1~rc.1-1"

# --- a real apt client ----------------------------------------------------------

expect 0 "" apt_update
sudo apt-get install -y -qq dashmate > /dev/null
[ "$(installed)" = "5.1.0-1" ] || fail "installed $(installed) from stable"
ok "apt installs 5.1.0-1 from stable"

make_release v5.1.1 '5.1.1-1'
sign_release v5.1.1 "$MAINTAINER"
expect 0 "stable: + arm64 5.1.1-1" publish v5.1.1
expect 0 "" apt_update
sudo apt-get install -y -qq --only-upgrade dashmate > /dev/null
[ "$(installed)" = "5.1.1-1" ] || fail "upgrade left $(installed)"
ok "apt upgrades to 5.1.1-1"

sudo apt-get install -y -qq --allow-downgrades dashmate=5.1.0-1 > /dev/null
[ "$(installed)" = "5.1.0-1" ] || fail "rollback left $(installed)"
ok "apt rolls back to 5.1.0-1 from the pool"

use_suite testing
expect 0 "" apt_update
sudo apt-get install -y -qq --allow-downgrades 'dashmate=5.1.0~rc.1-1' > /dev/null
[ "$(installed)" = "5.1.0~rc.1-1" ] || fail "pinning left $(installed)"
sudo apt-get install -y -qq dashmate > /dev/null
[ "$(installed)" = "5.1.1-1" ] || fail "a host on testing did not reach the final release: $(installed)"
ok "a host on testing installs a prerelease by version and still reaches the final release"

# --- Valid-Until ----------------------------------------------------------------

expect 0 "" apt_update faketime -f '+9d'
expect 100 "expired" apt_update faketime -f '+11d'
ok "apt accepts the Release nine days on and refuses it after eleven"

before="$(sha256sum < "$REPO/dashmate/dists/stable/InRelease")"
AGE=12 expect 0 "stable: unchanged and signed recently" publish
[ "$(sha256sum < "$REPO/dashmate/dists/stable/InRelease")" = "$before" ] || fail "a recent Release was signed again"
sleep 1
expect 0 "stable: published" publish
[ "$(sha256sum < "$REPO/dashmate/dists/stable/InRelease")" != "$before" ] || fail "the Release was not signed again"
ok "an unchanged suite is signed again once its Release is old enough"

KEY="$W/standby.key" expect 0 "stable: published" publish
expect 0 "" apt_update
ok "the standby subkey takes over with no change on the host"

# --- what must never happen -----------------------------------------------------

make_release v5.1.1 '5.1.1-1' "second build"
sign_release v5.1.1 "$MAINTAINER"
expect 2 "is already published with sha256" publish v5.1.1
ok "refused other bytes under a published version"

make_release v5.1.2-rc.1 '5.1.2~rc.1-1'
echo "x" >> "$REL/v5.1.2-rc.1/dashmate_5.1.2.rc.1-1_amd64.deb"
expect 2 "SHA256SUMS says" publish v5.1.2-rc.1
make_release v5.1.2-rc.2 '5.1.2~rc.3-1'
mv "$REL/v5.1.2-rc.2/dashmate_5.1.2.rc.3-1_amd64.deb" "$REL/v5.1.2-rc.2/dashmate_5.1.2.rc.2-1_amd64.deb"
mv "$REL/v5.1.2-rc.2/dashmate_5.1.2.rc.3-1_arm64.deb" "$REL/v5.1.2-rc.2/dashmate_5.1.2.rc.2-1_arm64.deb"
(cd "$REL/v5.1.2-rc.2" && sha256sum dashmate* > SHA256SUMS)
expect 2 "expected 5.1.2~rc.2-<revision>" publish v5.1.2-rc.2
ok "refused a deb that is not what SHA256SUMS lists, and one whose version is not its tag's"

cp "$REPO/dashmate/dists/dev/Release" "$W/Release.saved"
sed -i 's/^Label: dashmate$/Label: dashmatE/' "$REPO/dashmate/dists/dev/Release"
expect 2 "gpgv reports BADSIG" publish
cp "$W/Release.saved" "$REPO/dashmate/dists/dev/Release"
index="$(ls "$REPO"/dashmate/dists/dev/main/binary-amd64/by-hash/SHA256/* | head -n 1)"
for file in "$REPO"/dashmate/dists/dev/main/binary-amd64/by-hash/SHA256/*; do cp "$file" "$file.saved"; echo >> "$file"; done
expect 2 "is not what Release lists" publish
for file in "$REPO"/dashmate/dists/dev/main/binary-amd64/by-hash/SHA256/*.saved; do mv "$file" "${file%.saved}"; done
[ -n "$index" ] && expect 0 "" publish
ok "refused to build on a published suite that does not verify"

echo "5.1.1-1   # test" > "$W/withdrawn.txt"
expect 0 "stable: - amd64 5.1.1-1 (withdrawn)" publish
carries stable "5.1.0-1"
carries dev "5.1.0-1 5.1.0~rc.1-1 5.1.0~~dev.4-1 5.1.1~rc.1-1"
make_release v5.1.1 '5.1.1-1'
sign_release v5.1.1 "$MAINTAINER"
expect 2 "is withdrawn" publish v5.1.1
[ -f "$REPO/dashmate/pool/main/d/dashmate/dashmate_5.1.1-1_amd64.deb" ] || fail "a withdrawn version left the pool"
ok "a withdrawn version leaves every suite, stays in the pool, and cannot come back"

# --- a real release ---------------------------------------------------------------

if [ "${REAL:-}" = 1 ]; then
  export TO="$W/real"
  export BASE=https://github.com/dashpay/platform/releases/download
  # By hand a request is made for the SHA256SUMS the release has at that moment.
  SUMS="$(python3 -c 'import hashlib, sys, urllib.request; print(hashlib.sha256(urllib.request.urlopen(sys.argv[1], timeout=60).read()).hexdigest())' "$BASE/v5.1.0-rc.1/SHA256SUMS")"
  export SUMS
  expect 0 "testing: + arm64 5.1.0~rc.1-1" publish v5.1.0-rc.1
  carries stable ""
  carries testing "5.1.0~rc.1-1"
  sed -n '1,/^$/p' "$TO/dashmate/dists/testing/main/binary-amd64/Packages" | grep -vE '^(MD5sum|SHA1|SHA512):'
  ok "published the real v5.1.0-rc.1 of dashpay/platform"
fi

echo "ALL PASSED"
