# The archive keyring

`dashmate-archive-keyring.gpg` is the repository's public key, binary
(`gpg --export`), with both signing subkeys. It is the file operators get as
`/usr/share/keyrings/dashmate-archive-keyring.gpg`. Fingerprints and expiry
are in `../../README.md`, "The key".

```sh
gpg --show-keys --with-subkey-fingerprints dashmate-archive-keyring.gpg
```

The publisher refuses to run without it, and refuses to publish anything this
keyring does not verify.
