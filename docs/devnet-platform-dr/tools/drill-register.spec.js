// Registers one identity and prints its id. Mounted into the Platform test-suite image.
// Builds its own clients because the suite's helpers do not pass a devnet's block
// settings (powtargetspacing, minimumdifficultyblocks) to header validation.
const Dash = require('dash');
const fundWallet = require('@dashevo/wallet-lib/src/utils/fundWallet');
const { contractId } = require('@dashevo/dpns-contract/lib/systemIds');
const getDAPISeeds = require('../../lib/test/getDAPISeeds');
const createPlatformProofVerifier = require('../../lib/test/createPlatformProofVerifier');

function client(wallet) {
  return new Dash.Client({
    seeds: getDAPISeeds(),
    network: process.env.NETWORK,
    timeout: 25000,
    platformProofVerifier: createPlatformProofVerifier(),
    apps: { dpns: { contractId } },
    blockHeadersProviderOptions: {
      // powtargetspacing is left at the library default: dash-spv 5.0.3 refuses 10 s,
      // and below minimumdifficultyblocks the spacing is not used.
      minimumDifficultyBlocks: Number(process.env.DRILL_MIN_DIFF_BLOCKS),
    },
    wallet,
  });
}

describe('drill: write', function drillWrite() {
  this.timeout(900000);

  it('registers an identity', async () => {
    const unsafeOptions = { skipSynchronizationBeforeHeight: process.env.SKIP_SYNC_BEFORE_HEIGHT };
    const faucet = client({ privateKey: process.env.FAUCET_PRIVATE_KEY, unsafeOptions });
    const user = client({ mnemonic: null, waitForInstantLockTimeout: 120000 });
    try {
      await fundWallet(faucet.wallet, user.wallet, 30000000); // 0.3 Dash
      const identity = await user.platform.identities.register(20000000); // 0.2 Dash
      // eslint-disable-next-line no-console
      console.log(`DRILL_IDENTITY=${identity.getId().toString()} balance=${identity.getBalance()}`);
    } finally {
      await user.disconnect();
      await faucet.disconnect();
    }
  });
});
