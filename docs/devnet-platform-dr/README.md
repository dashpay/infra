# Platform disaster recovery on a console devnet

How to back up and restore Platform on every validator of a devnet created by
the status console, and how to roll whole hosts back from disk snapshots.
Written from the exercise in #27, run on 2026-11-20 and 21 on a throwaway
devnet (13 validators and a wallet host; Core 24.0.2, Drive and DAPI 5.0.3,
Tenderdash 1.8.2). Every step below was run there. [RESULTS.md](RESULTS.md)
has the timings and the evidence for each statement.

The console has no backup, restore or node-replace action, so all of this is
node-side work. The console is only used to create, watch and delete the devnet.

## What a validator holds

Everything is on the instance's one root disk.

| What | Where | In a backup? |
|---|---|---|
| Tenderdash data (blocks, state) | Docker volume `<project>_drive_tenderdash` | Yes |
| Drive data (GroveDB) | Docker volume `<project>_drive_abci_data` | Yes |
| Node configuration: dashmate config, Tenderdash `node_key.json`, genesis, gateway TLS, `secrets.json` | `/var/lib/dashnet` | Yes |
| Core's quorum data (DKG key shares, recovered signatures) | `llmq` in the Core volume | Copied, but see rule 1 |
| Core's chain | Core volume | No. It resyncs from the other nodes |

There is no `priv_validator_key.json` and no `priv_validator_state.json`.
Tenderdash signs through Core, so the signing keys are the key shares in
Core's `llmq` directory.

## Rules

1. **Restore Platform only. Leave Core and its `llmq` directory alone.**
   A running Core holds key shares for every quorum formed since the backup.
   Replacing `llmq` with an older copy removes them, and Platform halts at the
   first validator-set change to a quorum formed in that gap:
   `failed to create sigShare … quorum_hash=…`. It does not recover by itself.
2. **A Platform backup can be old.** Core 24 keeps the key shares of the
   last 1,440 Platform quorums (`keepOldKeys` in `src/llmq/params.h`): four
   days on a devnet with a DKG every four minutes, two months at one DKG an
   hour. An 85-minute-old backup,
   whose quorum had left the active list an hour earlier, restored cleanly.
3. **Backups of different validators do not need a common moment.** The
   network comes back at the newest height any archive holds, and nodes
   restored below it fetch the missing blocks from the others. Take the last
   copy as late as possible: that is the height you get.
4. **After a restore, everything written after the newest backup is gone.**
   Identities registered after the backup were not found afterwards.
5. **Snapshot a host only after flushing Core, with mining paused.** A running
   Core writes its block index hourly and its chain state daily. A snapshot
   taken without a flush brings Core back up to an hour behind Platform.
6. **After restarting every Core at once, keep the miner stopped until every
   Core reports masternode sync complete.** With 10-second blocks the sync
   never finishes while blocks keep arriving, and Platform stays down.
7. **A validator that is down across a DKG is PoSe-banned.** One missed
   window is enough on a devnet. Revive it (below); Tenderdash will not start
   on a banned node.

## Setting up

The tools in [`tools/`](tools/) run on a controller: any machine with AWS
credentials for the devnet's account, Python with `boto3`, `ssh`, and Docker
if you want the identity checks. They reach the nodes with EC2 Instance
Connect, as `ubuntu`, with strict host-key checking.

```sh
export DRILL_NET=devnet-<name>     # the devnet's name in the console
export DRILL_HOME=~/dr             # tools/, archives/, state/, known_hosts
mkdir -p "$DRILL_HOME" && cp -r tools "$DRILL_HOME/"
# Host-key pins: copy the console's file for this devnet from the status host,
#   /srv/dash-status/agent/devnets/<name>/known_hosts  ->  $DRILL_HOME/known_hosts
cd "$DRILL_HOME"
python3 tools/drill.py hosts
python3 tools/drill.py watch 1     # one line: heights, app hashes, restarts, Core state
```

Archives hold node keys and operator keys. Keep `archives/` mode 700 and
delete it when the devnet is deleted.

## Back up

Three ways, all tested. Each writes one archive per validator into
`$DRILL_HOME/archives/` with a manifest (heights, hashes, image ids, checksum).

| Method | Command | Cost | Use when |
|---|---|---|---|
| Coordinated, cold | `tools/coordinated-backup.sh <label>` | Platform down on the whole devnet, and mining paused, for about 2.5 minutes | You want one known height and app hash on every node |
| Rolling, live | `tools/rolling-backup.sh <label> live` | Nothing stops | The devnet must stay up. Tested on a quiet chain only |
| Rolling, cold | `tools/rolling-backup.sh <label> cold` | One validator down for a little over 2 minutes at a time; the network keeps producing blocks | A consistent copy per node without a network outage. Backup timed on three nodes; a fleet restore from such a set was not run |

The coordinated backup pauses the miner, stops Platform and then Core on
every validator, archives, starts Core, waits for masternode sync (rule 6),
resumes the miner and starts Platform.

## Restore Platform on every validator

Core stays up throughout.

```sh
tools/restore-fleet.sh <label> platform
```

It copies the archives to the nodes, stops Platform, replaces the two
Platform volumes and the node's Platform configuration, and starts Platform on
all validators at once. On each node Drive starts first, then Tenderdash,
DAPI and the gateway. No order between nodes is needed.

What to expect:

- Every validator answers at its archive's height within seconds of the start.
- The first new block comes after the empty-block interval (3 minutes on a
  console devnet) unless a transaction arrives sooner.
- From a coordinated backup: 2 minutes from "all Platform data gone" to
  Platform serving, 5 minutes to the first new block.
- If the backup's validator quorum is no longer active, the first block is
  still signed by that old quorum; the next block moves to a current one.

Do not use `restore-fleet.sh <label> platform+llmq` on a devnet whose Cores
are intact. It exists because the exercise had to show what happens (rule 1).

## Roll whole hosts back from snapshots

This covers what a file archive cannot: a broken host. EC2 replaces the root
volume from a snapshot and reboots the instance. Instance id, address and SSH
host key stay the same, so the console keeps recognising the node.

Take the snapshots:

```sh
D="python3 tools/drill.py"
$D node wallet miner stop
$D watch 1                         # wait until chainlock equals core on every node
$D node all flush-core             # every line must show the same height and block
python3 tools/snapshots.py create <label>
$D node wallet miner start
python3 tools/snapshots.py status <label>
```

Mining was paused for under two minutes. Nothing else stops, and Platform
keeps producing blocks.

Roll back:

```sh
python3 tools/rollback-hosts.py <label> all          # lists what it would do
python3 tools/rollback-hosts.py <label> all --go
$D watch 600 15                    # wait for synced=13
$D node wallet miner start
```

The miner was stopped when the snapshots were taken, so it stays stopped
after the reboot. Start it once every Core reports masternode sync complete
(rule 6). All containers start by themselves. Measured: 8 minutes from the
request to Platform serving on 13 of 13, 10 minutes to the first new block.

`rollback-hosts.py` copies the old volume's tags to the replacement. The
console finds a devnet's volumes by those tags when it deletes the devnet.

One node can be rolled back the same way (`rollback-hosts.py <label>
validators-007 --go`): it was back at the tip in under four minutes, and it
was banned, because the reboot fell into a DKG.

## Prove it recovered

Containers running proves nothing. After every restore:

```sh
$D state <name>                    # one block hash and app hash on 13 of 13, at height 1 and at the two newest heights
$D node validators chainlocks <height> <height>     # same=True on every node
$D sh validators-001 "$(cat tools/quorums.sh)"      # new quorums with every member valid
$D sh validators-001 "$(cat tools/pose.sh)"         # no penalty, no ban
tools/suite.sh read <identity,identity>             # an identity from before the backup is found
tools/suite.sh write                                # a new identity can be registered
```

Recovered means: all validators at one height with one app hash, the height
passes the backup's height, block 1 is the original genesis, an identity from
before the backup can be read with a proof and a new one can be written, Core
shows every masternode `READY` with the ChainLock at the tip, the next two
Platform quorums form with every member valid, and no container restarts for
30 minutes.

## When it goes wrong

| What you see | Cause | What to do |
|---|---|---|
| After restarting every Core: `IsBlockchainSynced: false`, one peer, no ChainLock, Drive logs `waiting for core to sync` | Masternode sync cannot finish while 10-second blocks arrive (rule 6) | Stop the miner until `mnsync status` says `IsSynced` on every Core, then start it |
| Platform stuck at one height, Tenderdash logs `failed to create sigShare … quorum_hash=…` | Core has no key share for the current validator quorum (rule 1) | Stop Platform. Wait until no active Platform quorum dates from the gap (`quorums.sh`; 16 minutes on a devnet, about a day at one DKG an hour). Restore Platform again and start it |
| A few validators sit below the tip after a restore from uneven copies, Tenderdash logs `block sync has stalled but a peer still holds the block we need` | They asked peers that were still behind, and dropped them | `docker restart` that node's Tenderdash container. It is at the tip seconds later |
| After a host rollback Tenderdash restarts in a loop: `block not accepted by abci app`, Drive logs `InvalidChainLock … invalid signature` | Core came back behind Platform (rule 5) | On a devnet where every Core lost the same blocks it clears by itself once the new chain passes the old tip. Next time flush before the snapshot |
| A node is `POSE_BANNED`, Tenderdash logs `unexpected masternode state POSE_BANNED` | It missed a DKG (rule 7) | `$D revive <node>`. The transaction is not InstantSend-locked, so it is mined about 10 minutes later |
| `revive` fails with a JSON error | Wallet `dashnet` is not loaded: it does not load by itself after the wallet host reboots | `dash-cli loadwallet dashnet` on the wallet host, then revive again |

## Not tested

- A live copy of a busy chain. The devnet's Drive volume was 3 MB and `tar`
  saw no file change under it.
- A fleet restore from a rolling cold backup.
- A host that is gone, not just broken. The console pins instance ids and has
  no node-replace action, so a terminated instance cannot be put back.
- A partial fleet: fewer than all validators restored, the rest syncing from
  them.
- Testnet or mainnet. What carries over is in [RESULTS.md](RESULTS.md).

## Tools

| File | What it does |
|---|---|
| `drill.py` | Controller: runs the node script on a set of hosts, moves archives, watches the fleet, saves fleet state, revives a banned node |
| `dr-node.sh` | Runs on a node as root: info, stop and start, backup, restore, Core flush, chain-lock check |
| `coordinated-backup.sh`, `rolling-backup.sh`, `restore-fleet.sh` | The fleet procedures above |
| `snapshots.py`, `rollback-hosts.py` | EBS snapshots of every root volume, and root-volume replacement from them |
| `quorums.sh`, `pose.sh` | Platform quorums and PoSe state as one node's Core sees them |
| `suite.sh`, `drill-register.spec.js`, `drill-read.spec.js` | Register and read identities with the Platform test-suite image |
