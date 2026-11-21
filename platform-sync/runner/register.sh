#!/bin/bash
# Registers the runner with dashpay/infra and starts it.
# Reads a short-lived registration token on standard input, for example:
#   gh api -X POST repos/dashpay/infra/actions/runners/registration-token --jq .token | sudo ./register.sh
# The token is never written to disk outside the container's tmpfs.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
install -d -o 1001 -g 1001 -m 700 /srv/platform-sync/runner/registration /srv/platform-sync/runner/work
docker compose run --rm -T \
  -e RUNNER_URL=https://github.com/dashpay/infra \
  -e RUNNER_NAME="${RUNNER_NAME:-$(hostname)-platform-sync}" \
  -e RUNNER_LABELS=platform-sync \
  --entrypoint bash runner -euo pipefail -c '
    umask 077
    token_file=$(mktemp)
    trap '\''rm -f "$token_file"'\'' EXIT
    cat > "$token_file"
    test -s "$token_file"
    export RUNNER_REGISTRATION_TOKEN_FILE="$token_file"
    /opt/ci/bin/runner-entrypoint register
  '
docker compose up -d
