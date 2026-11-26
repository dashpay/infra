# Maintainer keys

One file per maintainer whose signature on a release's `SHA256SUMS` opens
`stable` for that release: `<primary key fingerprint>.asc`, the armored
public key, one key per file. The publisher refuses a file whose name is not
the fingerprint of the key inside it.

The list must be the `ALLOWED_SIGNERS` of
`scripts/release/sign_dashmate_checksums.sh` in `dashpay/platform`. A key
added there opens nothing until it is added here and applied.

To add one, check the fingerprint with its owner over a second channel, then:

```sh
gpg --armor --export-options export-minimal --export <fingerprint> > <fingerprint>.asc
```
