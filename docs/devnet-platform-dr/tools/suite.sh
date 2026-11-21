#!/usr/bin/env bash
# usage: suite.sh write | read <id,id,...>   -- register one identity, or read identities, with the Platform test-suite image
#   DRILL_SEEDS    comma list of DAPI seeds, for example seed-1.drill.networks.dash.org:1443
#   DRILL_DEVNET   the devnet's short name, for example drill
#   DRILL_SKIP     Core height the wallet may skip to (a little below the faucet key's first funding)
#   DRILL_SUITE    test-suite image; use the tag of the Platform release the devnet runs
#   faucet.key in $DRILL_HOME holds "<private key> <address>" of a funded key, mode 600
set -euo pipefail
cd "${DRILL_HOME:-$HOME/dr}"
if [ ! -f suite.env ]; then
  umask 077
  k=$(cut -d' ' -f1 faucet.key); a=$(cut -d' ' -f2 faucet.key)
  printf 'FAUCET_1_PRIVATE_KEY=%s
FAUCET_1_ADDRESS=%s
FAUCET_2_PRIVATE_KEY=%s
FAUCET_2_ADDRESS=%s
' "$k" "$a" "$k" "$a" > suite.env
fi
t=/platform/packages/platform-test-suite
docker run --rm --entrypoint bash --env-file suite.env \
  -e DAPI_SEED="${DRILL_SEEDS:?set DRILL_SEEDS}" \
  -e NETWORK=devnet -e EVO_SDK_DEVNET_NAME="${DRILL_DEVNET:?set DRILL_DEVNET}" -e NODE_ENV=test -e SKIP_SYNC_BEFORE_HEIGHT="${DRILL_SKIP:-1}" \
  -e DRILL_IDENTITIES="${2:-}" -e DRILL_POW_SPACING=10 -e DRILL_MIN_DIFF_BLOCKS=1000000 \
  -v "$PWD/tools/drill-register.spec.js:$t/test/drill/drill-write.spec.js:ro" \
  -v "$PWD/tools/drill-read.spec.js:$t/test/drill/drill-read.spec.js:ro" \
  -w "$t" "${DRILL_SUITE:-dashpay/platform-test-suite:5.0.3}" -c "yarn mocha --no-parallel test/drill/drill-$1.spec.js" 2>&1
