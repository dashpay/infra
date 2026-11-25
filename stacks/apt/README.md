# apt

The signed apt repository that distributes dashmate
([dashpay/platform#4246](https://github.com/dashpay/platform/issues/4246)).

```
Types: deb
URIs: https://apt.services.dash.org/dashmate
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/dashmate-archive-keyring.gpg
```

The dashmate package ships that file as a dpkg conffile, always naming
`stable`. An operator who edits it keeps their copy for ever, so **the URL
can never change.** The package also ships the keyring at the path above,
and `/etc/apt/preferences.d/dashmate.pref`, which pins the origin
`apt.services.dash.org` so that this repository can supply the package
`dashmate` and nothing else. The three files and their paths belong to
`dashpay/platform` (`packages/dashmate/deb/`).

A release from before the package shipped those files (`5.1.0~rc.1`) is
installed by hand, with the keyring this repository serves at
`/dashmate/dashmate-archive-keyring.gpg`. The procedure is in
[dashpay/platform#4246](https://github.com/dashpay/platform/issues/4246#issuecomment-7166669368),
so that URL has to stay as well.

## Suites

| Suite | Carries | For |
|---|---|---|
| `stable` | Final releases whose `SHA256SUMS` a maintainer signed | Mainnet nodes. The default |
| `testing` | Betas, release candidates and every final release | Operators who opted in to prereleases |
| `dev` | Dev builds, and everything in `testing` | Proving the pipeline. No network of ours installs from it |

Every suite exists and is signed from the first run, empty or not: a host
whose sources file names a suite without a signed `Release` fails
`apt-get update`.

Nothing is ever removed from the pool, so `apt install dashmate=<version>`
works for every version that was published.

## How a release gets in

1. A job in `dashpay/platform`'s release workflow assumes the role
   `dashmate-apt-release` and starts the state machine
   `dashmate-apt-publish` with `{"tag": "v5.1.0"}`. That is all the role can
   do. It cannot start the publisher directly, read the key or write the
   bucket.
2. The state machine runs the CodeBuild project `dashmate-apt-publish`, one
   run at a time; a second request waits for the first.
3. The publisher (`publisher/`) downloads the two debs of that tag from the
   GitHub release, checks them against the release's `SHA256SUMS`, checks
   that each deb's version is the one the tag stands for, and adds them to
   the suites the release belongs in.
4. A final release without a maintainer's `SHA256SUMS.asc` goes to `testing`
   and `dev` only. Once the signature is attached, the next run, at the
   latest the daily one, moves it into `stable`. Nobody has to ask.

The publisher refuses, and changes nothing, when: the tag is not a release
tag; the release has no `SHA256SUMS`; a deb is not what `SHA256SUMS` lists;
a version is already published with other bytes (a rebuild needs a new
Debian revision); or what is published does not verify against the keyring.

The platform repository needs, once: an environment named
`dashmate-apt-publish` restricted to `v*` tags (the role trusts
`repo:dashpay/platform:environment:dashmate-apt-publish`, and that
restriction is what keeps branches out), and a job in it that runs

```sh
aws stepfunctions start-execution --state-machine-arn <state_machine_arn> \
  --name "<tag with dots as dashes>-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" --input '{"tag":"<tag>"}'
```

and then waits on `aws stepfunctions describe-execution` until the status is
no longer `RUNNING`. Both ARNs are in the output `repository`.

## Every day

Each `Release` says `Valid-Until`, ten days ahead. Without it a signed
snapshot is valid for ever, and whoever sits between a host and the
repository could hold the host on an old one. The schedule
`dashmate-apt-publish-daily` (05:17 UTC) signs every suite again, so nine
runs in a row have to fail before a host sees `Release file ... is expired`.

**If the daily run stops, every host stops updating ten days later.** Check
`Date:` in `https://apt.services.dash.org/dashmate/dists/stable/InRelease`;
it should be less than two days old. The log is the group
`/aws/codebuild/dashmate-apt-publish`; a run that needs a person says
`REFUSED:` or `NEEDS A PERSON:`.

## The key

One OpenPGP key, used for nothing else, made on 2026-11-25:

| | Fingerprint | Expires |
|---|---|---|
| Primary (certifies only) | `A5F9 0926 475E F253 46DC  E268 36EF 5BF8 53D1 00FE` | 2027-11-25 |
| Signing subkey, online | `94E1 AA92 32F7 10AF 5140  0D22 42D0 7EC5 97C9 2A74` | 2027-11-25 |
| Signing subkey, standby | `51C0 AF25 3270 F3DA CE9F  4007 8A30 392F 222E 0ACC` | 2027-11-25 |

`Dashmate APT repository <infrastructure@dash.org>`

- **The primary key** certifies only. It is never in AWS or GitHub; the head
  of infrastructure holds it, together with the standby subkey.
- **Two signing subkeys.** One is online: the secret
  `dashmate-apt/signing-key` in Secrets Manager, which only the publisher's
  role reads. The other is the standby, kept with the primary.
- **The keyring** operators get is the public key with both subkeys:
  `publisher/keyring/dashmate-archive-keyring.gpg`. The dashmate package
  installs it; the repository also serves it at
  `/dashmate/dashmate-archive-keyring.gpg` for a first install by hand.

apt has no revocation. A host trusts exactly the keyring file it has, so:

- **If the online subkey leaks:** put the standby subkey in the secret
  (below) and run the publisher. Hosts notice nothing: the standby is already
  in their keyring. Then make a new standby, ship a keyring without the
  leaked subkey in the next dashmate release, and announce it. Until a host
  installs that release, the leaked subkey can still sign for it, to anyone
  who can also put themselves between that host and the repository.
- **Before the key expires:** extend the primary's and the subkeys' expiry,
  commit the new keyring here and hand it to the platform side at least
  three months ahead (by 2027-08-25 for this key), so that it reaches hosts
  in a dashmate release before the old one runs out. A host that misses it gets
  `EXPKEYSIG` and stops updating until it installs a newer deb by hand.
  A host that set the repository up by hand (above) holds a copy of the
  keyring that no package renews, until its operator moves to the package's
  own files.
- **If the primary key leaks, or is lost:** there is no quiet way out. A new
  key means a new keyring on every host, which reaches them only through a
  dashmate release installed from the old key, or by hand.

### Making a key

How this one was made, and how to make its successor. The primary secret key
belongs on a machine and on storage that the publisher, AWS and GitHub never
see:

```sh
gpg --quick-generate-key 'Dashmate APT repository <infrastructure@dash.org>' ed25519 cert 1y
gpg --quick-add-key <fingerprint> ed25519 sign 1y    # the online subkey
gpg --quick-add-key <fingerprint> ed25519 sign 1y    # the standby
gpg --export <fingerprint> > dashmate-archive-keyring.gpg
gpg --export-secret-subkeys '<online subkey fingerprint>!' > signing-key.bin
```

Then:

1. Commit `dashmate-archive-keyring.gpg` to `publisher/keyring/` and apply.
2. `aws secretsmanager put-secret-value --secret-id dashmate-apt/signing-key --secret-binary fileb://signing-key.bin`,
   and destroy `signing-key.bin`.
3. Start the state machine with `{}`. On a new repository it must publish
   three empty suites.
4. Give the platform side the keyring file and the fingerprint.

`schedule_enabled = false` turns the daily run off, for a repository that
has no key.

The publisher refuses a secret that holds the primary secret key, or more
than one signing subkey, or a key other than the keyring's.

## Maintainer keys

`publisher/maintainers/<fingerprint>.asc`, one file per maintainer whose
signature opens `stable`. See the README there.

## Withdrawing a release

Add its Debian version to `publisher/withdrawn.txt`, apply, and start the
state machine with `{}`. It leaves every suite and cannot be published
again; its file stays in the pool. Hosts that already installed it keep it:
apt never downgrades, so the fix is a higher version.

## Changing the publisher

`publisher/` is zipped and uploaded by `terraform apply`, and the project
runs that upload by its S3 version. Before applying a change:

```sh
python3 -m unittest discover -s stacks/apt/publisher/tests
```

and, on a disposable Ubuntu machine, `tests/integration.sh`, which publishes
with throwaway keys and installs, upgrades, rolls back and expires with a
real apt client.

## What this stack does not hold

- The zone `services.dash.org` (`stacks/services/`).
- The keys. Neither the primary nor a subkey is a Terraform resource; the
  secret's value is put there by hand.
- The trigger job and the environment in `dashpay/platform`.
- What tells a person the daily run failed. Nothing in AWS can reach our
  Slack, so the check above is made from outside: since 2026-11-25 a timer on
  infraclaw's operations host reads `InRelease` of every suite each 15
  minutes, verifies it against a copy of the keyring, and says in Slack when
  a suite was not signed again for 40 hours, has under four days left, has
  expired, cannot be fetched, or is not signed by this key. That copy of the
  keyring has to be replaced whenever the keyring here is.
