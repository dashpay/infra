# Devnet Platform DR exercise (#27): results

The record behind [README.md](README.md). Devnet `devnet-drill`, created through the
status console for this exercise and deleted after it: 13 validators (`t4g.medium`,
arm64) and `wallet-001` (`t3.large`). Core 24.0.2; Drive, rs-dapi and dashmate-helper
5.0.3; Tenderdash 1.8.2; genesis protocol 14. Core blocks every 10 s, Platform
empty-block interval 3 min, a Platform quorum DKG every 24 Core blocks (4 min), four
active Platform quorums of 12 members.

All times are UTC on 2026-11-20 unless a line says 11-21. "Wreck" means: stop Platform
on a validator, empty its Tenderdash and Drive volumes and remove its Platform
configuration directory.

## Runs

| Run | What was done | Result |
|---|---|---|
| 1 | Coordinated cold backup at Platform height 8. Platform data wiped on 13 of 13, restored, Core left running | Pass. Serving at height 8 after 2 min, new block after 5 |
| 2a | Live copies, one validator every 95 s, nothing stopped (heights 12 to 20). Wiped, restored | Pass. Back at height 20, the newest copy. Three nodes stalled in block sync for 10 min |
| 3a | A backup 85 min old, whose quorum had left the active list. Core left running | Pass. First block signed by the old quorum |
| 3b | The same backup, and Core's `llmq` directory replaced with the copy of the same age | Fail. Platform halts at the next validator-set change and does not recover |
| 3c | Recovery from 3b: wait for the gap quorums to leave the active list, restore Platform again | Pass, after a 16 min wait |
| 4, one node | One validator's root volume replaced from a snapshot | Works. At the tip after 3 min 37 s, and PoSe-banned: the reboot fell into a DKG |
| 4a | All 14 hosts rolled back from snapshots taken with everything running | Not a procedure. Core came back up to 58 min behind Platform and forked below it; Tenderdash crash-looped for 10 min; recovered by itself after 14.5 min |
| 4b | All 14 hosts rolled back from snapshots taken with the miner paused and every Core flushed | Pass. Serving after 8 min, new block after 10, no restart loop, no ban |

## Answers to the issue's questions

**Is the backup scope sufficient for full-cluster recovery?** Yes, and it is smaller
than expected. The Tenderdash volume, the Drive volume and the node's Platform
configuration directory, restored on every validator, bring the network back (runs 1,
2a, 3a). There are no validator key or state files to find: Tenderdash signs through
Core. Core's `llmq` directory is the signing material, and it must not be restored
over a running Core (run 3b).

**How coordinated do fleet backups need to be?** Between validators, not at all in
this test: copies taken 19 minutes and 8 blocks apart restored to one network at the
newest height (run 2a). The limits of that result: a quiet chain, and three nodes that
needed a Tenderdash restart or ten minutes. What does need care is the pairing of
Platform data with Core: a restore must leave Core's current key shares in place (3b),
and a host snapshot must hold a Core that is not behind its Platform (4a against 4b).

**What start order is required?** On a node: Drive, then Tenderdash, DAPI, gateway;
stop in the reverse order, Tenderdash first. Between nodes: none, all 13 were started
at once every time. Before Platform can do anything Core must have finished masternode
sync, and after a restart of every Core that needs the miner paused (finding A).

**Are more paths needed than the HPMN backup scope?** No. For a broken host the answer
is a snapshot of the root disk, not more paths in the archive.

**What proves the devnet is recovered?** One block hash and app hash on 13 of 13 at
two heights above the backup; block 1 still the original genesis; an identity written
before the backup read back with a proof, and a new one registered; Core `READY` and
synced on 13 with the ChainLock at the tip; the next Platform quorums formed with 12
of 12 valid; no container restart in 30 minutes. Identities written after a backup
were missing after every restore, as they must be.

## What carries over to testnet and mainnet

Nothing here was run on testnet or mainnet. From the same software one should expect:

- Rule 1 (do not restore `llmq` over a running Core) holds, and the wait in run 3c
  becomes about a day: 24 active Platform quorums, one DKG an hour.
- A Platform backup stays restorable for about two months (`keepOldKeys` = 1,440
  quorums at one DKG an hour).
- A snapshot of a running Core is up to an hour behind. Where other nodes hold the
  chain, that Core simply resyncs; the fork in run 4a needs every Core to lose the same
  blocks.
- The masternode-sync stall (finding A) needs blocks faster than 30 s. It should not
  happen at 2.5-minute blocks.
- A node that is away during a DKG is punished there too.

What a devnet this small cannot show: copy and transfer times for real state (the
archives here were 1.4 to 2.6 MB), live copies of a busy database, and a network where
some validators belong to someone else.

## Not established

- Why validators-005 and validators-009 were given a PoSe penalty of 66 (run 4, one node).
- Why a Core restarted alone finishes masternode sync with mining on, and a fleet
  restarted together does not (finding A). Peer count is the visible difference.
- Why no Platform quorum formed at Core 7608, the first DKG after the rollback in run 4b.

## Setup

- 19:55:29 create request `d6677b10` (plan `6a00c214…`), confirmed 19:55:56, succeeded 20:07:48. Platform start operation `1098ecec`.
- 20:19 Platform at height 2 on 13 of 13, one block hash and app hash. Genesis (height 1) block `5CBA9B9950AAA6AB…`, app hash `A05B56AA5B10C610…`.
- Funding key generated inside the test-suite image, 30 DASH sent from the devnet wallet `dashnet` (six transactions).
- Identity 1 `BBdjkZqHpv2EPp76dD2We2FLVLRooiBu4jMo9g5kLGv8` registered 20:26 (balance 19883683420), read back with proofs.
- JS SDK on this devnet: `dash-spv` 5.0.3 rejects headers unless `blockHeadersProviderOptions.minimumDifficultyBlocks` is passed (1000000 here); it refuses `powTargetSpacing: 10` outright ("Unsupported block spacing 10"), so the spacing is left at the default. The suite's own helpers pass neither.

## Finding A: a fleet-wide Core restart stalls masternode sync while mining continues

- 20:28 first coordinated backup `b1` (Platform height 6, app hash `49F29B37A062454F…`, Core 4357): miner paused, Platform stopped, Core stopped on all 13, archived, Core started.
- The miner was resumed 13 s after Core start because `masternode status` said READY on 13 of 13. That is not masternode sync.
- 20:29–20:36: every validator Core had `IsBlockchainSynced: false`, 1 peer, no ChainLock ("Unable to find any ChainLock"); Drive logged `waiting for core to sync`; Tenderdash RPC did not answer. DKG sessions in that window failed (the quorum list did not change).
- Cause, read in Core `v24.0.2` on 11-21: the blockchain stage of masternode sync ends after `MASTERNODE_SYNC_TIMEOUT_SECONDS` = 30 s (`src/masternode/sync.h`, with the comment "nominal target spacing is 2.5 minutes, so 30 seconds should be fine"), and every new header postpones it (`CMasternodeSync::AcceptedBlockHeader`, `src/masternode/sync.cpp`). With 10 s blocks it never elapses. A node restarted alone, with 12–13 peers, did finish in about 65 s with mining on (per-node cold backup, below); why peers make the difference was not read in the source.
- 20:36:48 miner stopped; ChainLock at the tip by 20:38:11; Platform block 7 by 20:41:46, 13 of 13.
- The console engine does the same thing at creation ("waiting for masternode sync with mining paused").
- Fixed in `coordinated-backup.sh` and `restore-fleet.sh`: keep the miner stopped until `mnsync status` says `IsSynced` on every Core. With that, sync took 80 s (b2).

## Run 1: coordinated cold backup, restore with Core left running — PASS

- Backup `b2` 20:45:00–20:48:38. Platform height 8, block `A29E45242B2B7357…`, app hash `B0D7CB6906D1A81D…`, validator quorum `33258b9f…`, Core 4427. Platform was down 20:45:12–20:47:38. 13 archives, 1.4–1.6 MB each.
- After the backup: identity 2 `B5fg6SkAoJvzDWFQkUmT1ZBkskwS9KvgafjYuTa7h79P` registered (20:51); Platform at height 10 (old block 9 `D9CB49502CEAD7CD…`).
- 20:52:28 wreck on 13 of 13: Platform stopped, Tenderdash and Drive volumes emptied, `…/dashmate/<node>/platform` removed. Core untouched and running.
- 20:52:52 push archives, 20:53:38 restore (scope `platform`), 20:54:19 Platform started on all 13 at once.
- 20:54:31 13 of 13 at height 8, same app hash. Block 9 between 20:57:00 and 20:57:30 (new block `C61D6A16CC3FD32B…`), validator set moved to quorum `4b08dd44…`.
- Disaster to Platform serving at the backup height: 2 min. To the first new block: about 5 min, of which 3 is the empty-block interval.
- Checks at 21:00: height 1 and height 8 hashes identical to before on 13 of 13; no container restarts; Core READY, synced, ChainLock at tip on 13 of 13.
- Identity 1 found with the same balance; identity 2 MISSING (it was written after the backup: that is the data loss a restore implies); identity 3 `EmGJb2DuynGrjnsacm5VetSYHdTthf56DL9Kw14x7Gki` registered 21:03.
- Core kept its live `llmq` directory. No signing problem although block 9 was signed a second time with different content.
- Soak to 21:24 (30 min after the restore): Platform 8 → 20, 0 container restarts on 13 of 13, four new Platform quorums formed (Core heights 4560, 4584, 4608, 4632), each 12 of 12 valid; the validator set moved onto them.

## Run 2a: live copies taken node by node (the April method), restore with Core left running — PASS, with a stall on 3 nodes

- Backup `b3live` 21:04:20–21:23:04, one validator every 95 s, nothing stopped, two identity registrations running meanwhile (identity 4 `BJQWFRuPJ11DSB1BtJByDJbPNM1CegVn43zZzbyTCSUJ`, identity 5 `BxK7VZNff4MQDTXCvsAN7dCtA5D6UbbUBc4fPpurkcff`).
- Heights in the archives: 12 (001, 002), 13 (003, 004), 15 (005, 006), 17 (007, 008), 18 (009, 010), 19 (011, 012), 20 (013). `tar` reported no file changing under it on any node (Drive 3 MB, Tenderdash 1 MB, a quiet chain). That is weaker than a busy testnet node.
- 21:25:45 wreck on 13 of 13 at Platform height 20. 21:26:49 restore (scope `platform`), 21:27:29 Platform started on all 13.
- 21:27:41: 9 of 13 already at height 20; the nodes restored below it replayed blocks from the others (001 went 12 → 17 in one second). Block 21 at about 21:30:40, block 22 at 21:34:58.
- **The network came back at the newest height any archive held (20), not the oldest (12).** Block 20 after the restore is the pre-disaster block (`B68EBD7F8971F903…` / app hash `DAFBA0CA887C3521…`) on 13 of 13. Nothing was lost here because the last archive was taken at the tip.
- **Three nodes stalled in block sync** (001, 004, 007) at height 17 for about 10 minutes: Tenderdash logged `removing peer after too many consecutive failed block requests … peer did not send us anything` at 21:27–21:28 (the peers were themselves still below that height), then `block sync has stalled but a peer still holds the block we need` every second. The other ten carried consensus (two rounds at height 22 went nil first).
- 21:37:31 `docker restart` of Tenderdash on 001: at height 22, not catching up, 25 s later. 004 and 007 were at the tip in the next sample (21:38:20) without being touched.
- Checks at 21:39: 13 of 13 at height 22, one block hash and app hash at 1, 20, 21, 22; identities 1, 3, 4, 5 found with their balances; identity 6 `DmBXK5j9XzK3can96tnV2fQcr6dJ2AUGNvZQbKZZT9Pq` registered 21:43.

## Snapshots for run 4

- `s1`: 14 EBS snapshots of the root volumes, started 21:15:45.570–21:15:55.010 with everything running (Platform height 17 at that moment).
- Soak for run 2a to 21:53 (26 min): Platform 20 → 28, 0 container restarts.

## Per-node cold backup, timing only (three nodes, no fleet restore)

- 21:43–21:52 on 005, 009, 012, one after another: stop Platform, stop Core, archive, start Core, wait for masternode sync, start Platform.
- Platform on the node was down 2 min 15 s each time (21:43:47 → 21:46:00 on 005). Of that about 65 s is Core's masternode sync after its restart (it has 12–13 peers, so it completes with the miner running) and most of the rest is the controller's own SSH round trips.
- Each node was back at the tip and not catching up within 12 s of Platform starting. The other 12 kept producing blocks (25 → 28). Archives 2.5–2.6 MB.

## Run 3a: 85-minute-old backup, Core left running with its live llmq — PASS

- Archive `b1` (20:28, Platform height 6, validator quorum `33258b9f…`, formed at Core height 4296). At the restore Core was at 4838 and its four active Platform quorums were from heights 4728–4800: the backup's quorum had left the active list more than an hour earlier.
- 21:54:07 wreck at Platform height 28. 21:55:11 restore (scope `platform`), 21:55:56 Platform started.
- 21:56:09 13 of 13 at height 6 (block `0849078A90B14720…`, app hash `49F29B37A062454F…`, as recorded at the backup).
- Block 7 at 21:59:06, **signed by the old quorum `33258b9f`** at Core chain-locked height 4855. Block 8 at 22:02:08 signed by `7fd63e14`, a current quorum.
- `quorum info 107 33258b9f… true` on validators-001 at Core 4890: `secretKeyShare` present. Core 24.0.2 keeps key shares for Platform quorum types for `keepOldKeys = 24 * 30 * 2` = 1,440 quorums (`src/llmq/params.h`; the comment there: "Platform can be restarted and it must be able to re-sign stuff"). At one DKG per hour on testnet and mainnet that is two months; on this devnet (a DKG every 4 minutes) four days.
- Checks at 22:04: 13 of 13 at height 8, one hash at 1, 6, 7, 8; identity 1 found; identities 3, 4, 5, 6 MISSING (all written after 20:28); identity 7 `AT2rd1brWzkCAmkciT6i18ZPHKXBqo4aDiCe1Q1v1bZx` registered 22:08.

## Run 3b: the same stale backup, and Core's llmq directory replaced with the stale copy — FAIL (Platform halts)

- 22:09 wreck at height 9. Miner paused, Core stopped on 13 of 13, `llmq` replaced with the 20:28 copy (taken at Core 4357), Core started, masternode sync 80 s, miner resumed 22:12:54, Platform started 22:13:29. Core was at 4926.
- **ChainLocks stopped**: best ChainLock stayed at 4926 while Core went to 4962 (6 minutes), then came back in steps as quorums formed after the restore took over (4968 at 22:20, 4976, 4986).
- Block 7 at about 22:17, signed by the old quorum (its share was in the stale copy). Drive then moved the validator set to `6e31e70c…`, formed at Core 4896: after the backup, before the restore.
- **Height 8 never came.** Tenderdash on every node: `failed signing vote … cannot sign vote: exhausted 4 retry attempts: -8: failed to create sigShare … quorum_hash=6E31E70C…`. No node holds a share for a quorum formed in the gap, and the validator set cannot move without a signed block. Still at 7 at 22:24.
- It did not recover by itself: still at height 7 at 22:29, 12 minutes after the block, with ChainLocks already back.

## Run 3c: recovery from 3b — PASS

- Waited until none of Core's four active Platform quorums dated from the gap (22:30:00, Core 5027: quorums from 4944, 4968, 4992, 5016, all formed after the 22:12 Core start).
- 22:30:00 wreck, 22:30:58 restore `b1` again with scope `platform` (Core and its llmq not touched this time), 22:31:39 Platform started.
- Block 7 at about 22:34:50 signed by the old quorum, validator set moved to `37891f99…` (formed after the Core restart), block 8 at about 22:38. 13 of 13, one app hash, 0 restarts.
- So after any restore that leaves Core without shares for some active quorums, Platform must stay stopped until those quorums have left the active list: 4 quorums × 24 blocks here (16 minutes at 10 s blocks); **24 quorums × 24 blocks on testnet and mainnet, about a day.**
- Checks at 22:40: 13 of 13 at height 8, one hash at 1, 7, 8; identity 8 `14T3KwsuZtfSKT8wZgBD56eQv2DCKZbYVhJSF1DY3TBB` registered 22:45.

## Run 4, single-node pre-test: one validator rolled back from its snapshot — works, and the node is PoSe-banned

- Snapshots `s3`: 14 root volumes, started 22:45:31.822–22:45:40.744, everything running (Platform height 11, Core 5122). Completed within 2 minutes (`s1`, taken 21:15, likewise).
- Root volumes carry the tags the console uses to find a devnet's volumes at deletion (`dashnet:network`, `dashnet:managed-by`) and have `DeleteOnTermination: false`. A replacement volume starts untagged, so `rollback-hosts.py` copies the tags over. Without that the console's delete would leave the replacement volumes behind.
- Containers have restart policy `unless-stopped`: after a host rollback everything starts by itself, Platform included.
- 22:48:15 `CreateReplaceRootVolumeTask` on validators-013 (`i-03c5b5944557707c5`, snapshot `snap-069af866afc3580e3`); task succeeded 22:48:37 (22 s); new root `vol-033c179a74065341b`; same instance id, same address, same SSH host key.
- 22:50:05 containers started (110 s after the request). Core synced from 5122 to the tip by 22:51:17; Platform at the tip, not catching up, by 22:51:52. 3 min 37 s from request to a node serving at the tip.
- **The node came back `POSE_BANNED`.** It was absent during a DKG: penalty 0 → 66 at Core height 5147, 65 → 100 (ban) at 5148, one commitment per quorum type in consecutive blocks. Two quorum types run their DKG at the same height on a devnet, so one missed window is enough.
- Earlier punishments in the same log, neither a ban: validators-005 0 → 66 at height 4812 (21:51:46, six minutes after its per-node cold backup restart), validators-009 0 → 66 at height 5052 (22:34:03, nothing done to that node since the 22:11 fleet Core restart). The penalty falls by one per block; both were back at 0 by 22:52. Why those two were voted bad is not established.
- Revive: the console revives banned nodes only while it is creating a devnet or starting Platform, so by hand, the same way it does it: operator key from `/var/lib/dashnet/secrets.json` on the node, piped to `dash-cli -stdin protx update_service_evo` on the wallet host, fee from an unlocked output of wallet `dashnet` (`drill.py revive`). ProUpServTx `9d691e191230126316f2e6e67cf6507228f42c91b9f980b7159d72add297fc8d` sent 22:59:22.
- It was not InstantSend-locked (an ordinary payment sent at 23:04 was locked within 8 s), so miners hold it for 10 minutes.
- 23:09:42 validators-013 `READY` again (revived at Core 5264, 10 min 20 s after the ProUpServTx was sent). 23:10:05: 13 of 13 at Platform height 18, Core 5267.

## Run 4a: all 14 hosts rolled back from snapshots taken live — FAIL as a procedure (Core comes back behind Platform); the devnet recovered by itself after 13 minutes

- Snapshots `s4`: 14 root volumes, started 23:10:37.556–23:10:46.565, nothing stopped. Platform height 19 (block time 23:10:19), Core 5272 at 23:11:25.
- Identity 9 `GYLXicrRCcryUPu7MZA9AfdWyRtEP1qoAKmpberuCs9d` registered 23:13, after the snapshots. 23:14:29: Platform 21, Core 5291.
- 23:15:02 `rollback-hosts.py s4 all --go`: 14 tasks requested 23:15:20–23:15:33, succeeded 23:15:41–23:15:57. Wallet host answering SSH at 23:17:16; the miner had started by itself and was stopped again.
- **Core came back behind the snapshot.** 23:17:57: Core at 4926 on all 13 validators (the height of their last clean shutdown, 22:10, run 3b), 0 peers, not synced. The wallet host's Core was at 5218. 23:19:12 all at 5218; 23:19:48 masternode sync complete on 13, miner resumed. Blocks 5219–5291 of the old chain were on no disk; the miner built a new branch from 5218.
- Core 24.0.2 writes its block index hourly and flushes the chainstate daily or at shutdown (`DATABASE_WRITE_INTERVAL{1}` h, `DATABASE_FLUSH_INTERVAL{24}` h in `src/validation.h`, read at tag `v24.0.2`). A snapshot of a running Core therefore holds a chain up to an hour old. Platform's databases in the same snapshots were current (height 19).
- **Tenderdash crash-looped on every validator for 10 minutes**: `ERROR: failed to start node: error on replay: blockReplayer process proposal: block not accepted by abci app`; Drive: `Rejected invalid proposal for height: 19 … InvalidChainLock("core rpc error: … code: -8, message: \"invalid signature\"")`. Restart counters went from 0 to 646 across the fleet (46–58 a node).
- **ChainLocks stopped at 5217** from 23:20 until the new branch was past the snapshot's tip: best ChainLock 5217 at 23:27:49 (Core 5265), 5275 at about 23:29. Inferred, not read from a log: the Cores had already signed locks for those heights on the lost branch and would not sign a second block at the same height.
- 23:29:37: 12 of 13 at Platform height 19, one app hash, ChainLock at the tip. Block 20 at 23:31:39, block 21 at 23:35:04. Rollback request to Platform serving: 14 min 35 s; to the first new block: 16 min 37 s.
- **Platform blocks 18 and 19 now carry chain locks for Core blocks that are not on the Core chain** (read 05:55 from validators-001): block 18 locks Core 5251 `4dfbc556b1ae447e…`, the chain has `451950f1a588630a…`; block 19 locks 5269 `77666fdbeae04c7f…`, the chain has `0cc7dbce7e319e4b…`. Block 20 (5288 `4f408f01843f7e1f…`) matches. It works only because every Core on this devnet lost the same blocks; on a network where other nodes keep the chain this exact case cannot arise.
- **validators-013 was banned again**: its revival was in block 5264 of the lost branch. Tenderdash there: `failed to wait for masternode status 'ready': unexpected masternode state POSE_BANNED`.
- **Wallet `dashnet` was not loaded after the wallet host's reboot** (`listwallets`: `["faucet"]`), so `drill.py revive` failed. `loadwallet dashnet` at 23:36; the wallet re-broadcast the old ProUpServTx by itself (a second one was refused, `protx-dup`). `PoSeRevivedHeight` 5381.
- Checks at 23:31: identity 8 found, identity 9 MISSING (written after the snapshots), identity 1 found; identity 10 `Aq7NgTC3zhS62rkx4hTssAuk8nuGU7fgoLz8dd3CassV` registered 23:35.
- Soak, read 05:52 on 11-21 (6 h 20 min later; nothing was done to the devnet in between): 13 of 13 at Platform 144, one block hash and app hash at 1, 143, 144; Core 7569 with ChainLock at the tip; 13 `READY`; Tenderdash restart counters on the twelve unchanged since 23:30.

## Run 4b (11-21): all 14 hosts rolled back from snapshots taken with the miner paused and Core flushed — PASS

- 05:55:26 miner paused at Core 7588 (ChainLock 7588 on 13 of 13). 05:56:07–05:56:19 `dash-cli gettxoutsetinfo` and `sync` on all 14 hosts: the same height and best block on 14 of 14. `gettxoutsetinfo` calls `ForceFlushStateToDisk()` (`src/rpc/blockchain.cpp`, `v24.0.2`). Nothing was stopped.
- Snapshots `s5`: started 05:57:05.425–05:57:14.775. Miner resumed 05:57:15: mining was paused for 1 min 49 s. Platform block 146 (05:56:57) was produced during the pause, locking Core 7588.
- Identity 11 `3kkdSFemaNX2r4cTiLxD9hQMZjNop2UJ9iuMyRwRNzdt` registered 06:06, after the snapshots. 06:07:03: Platform 150, Core 7643.
- 06:07:13 `rollback-hosts.py s5 all --go`; tasks succeeded 06:07:54–06:08:10.
- 06:09:38 wallet host answering; the miner was `Exited (0)`, as in the snapshot (restart policy `unless-stopped` keeps a stopped container stopped).
- 06:10:06 Core at 7588 on all 13 validators. Masternode sync complete on 13 at 06:12:22. Miner resumed 06:12:27; ChainLock at the tip at 06:13:10.
- 06:14:58: 13 of 13 at Platform height 146, one app hash, 0 Tenderdash restarts, 13 `READY`. Block 147 at 06:17:23. Rollback request to Platform serving: 7 min 45 s; to the first new block: 10 min 10 s.
- Chain locks in Platform blocks 145, 146, 147 (Core 7578, 7588, 7616) equal the Core chain's blocks at those heights.
- Checks at 06:19: identity 10 found, identity 11 MISSING, identity 1 found; identity 12 `EiqdvMLgk3uYvj5TuSdELdL6M7cHzsZkywmWoD88MNmg` registered 06:24. 06:24:50: 13 of 13 at 150, one hash at 1, 149, 150. No PoSe penalty on any node.
- Wallet `dashnet` again not loaded after the reboot (`["faucet"]`).
- No Platform quorum formed at Core 7584 (its DKG was running when the snapshots were taken) or 7608. Quorums at 7632 and 7656 formed with 12 of 12 valid (read 06:27, Core 7676).
- Soak to 06:43:52 (31 min after the miner resumed): 13 of 13 at Platform 156, one hash at 1, 155, 156; 0 container restarts on the validators; Platform quorums from Core 7680, 7704, 7728, 7752, each 12 of 12 valid; no PoSe penalty.

## Not caused by the exercise

- The console shows `wallet-001` as down: `devnet-services-insight-1 restarting (exit 255)` (a block-parse error in `dashcore-lib`). Palmatum's `wallet-001` shows the same line.
- The console made no operation of its own on the devnet in the whole exercise: its list holds the create (`d6677b10`) and the Platform start (`1098ecec`) only.

## Teardown

- 06:44:37 console operation `495a97b7` (`delete-devnet`, `confirmName`). Review: 14 instances (all `devnet-drill-*`), 14 volumes, 7 DNS names. Confirmed 06:44:54, `succeeded` 06:45:59: 7 DNS records removed, instances terminated, addresses released, "Delete retained root volumes: 14 deleted, none left". The replaced root volumes were found because their tags had been copied.
- Checked in AWS afterwards (tag `dashnet:network=devnet-drill`): 14 instances `terminated`; no volume, address, network interface, security group or key pair; no record under `drill.networks.dash.org`. The console answers 404 for the network.
- 56 snapshots (`s1`, `s3`, `s4`, `s5`) deleted; none left. No `s2` set was ever taken.
- Controller: the archives (node and operator keys) and the faucet key were deleted.
- The devnet existed from 19:55 to 06:45 UTC, 10 h 50 min, at the console's estimate of $0.52 an hour: about $5.60.
