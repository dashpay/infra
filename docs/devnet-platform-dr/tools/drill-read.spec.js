// Reads identities named in DRILL_IDENTITIES (comma list) with proofs and prints their balances.
const createClientWithoutWallet = require('../../lib/test/createClientWithoutWallet');

describe('drill: read', function drillRead() {
  this.timeout(300000);

  it('reads the identities', async () => {
    const client = await createClientWithoutWallet();
    try {
      for (const id of process.env.DRILL_IDENTITIES.split(',')) {
        // eslint-disable-next-line no-await-in-loop
        const identity = await client.platform.identities.get(id);
        // eslint-disable-next-line no-console
        console.log(`DRILL_READ=${id} ${identity ? `found balance=${identity.getBalance()}` : 'MISSING'}`);
      }
    } finally {
      await client.disconnect();
    }
  });
});
