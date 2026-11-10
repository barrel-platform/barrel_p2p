# Verification

This page says what barrel_p2p's replication is proven to do, how it is
proven, and where the proof stops. Read it when you rely on the registry,
leader election, reminders or replicated maps staying consistent across
partitions, or when you change `barrel_p2p_replica` or `barrel_p2p_ormap`.

## What is checked

Two layers check the same algorithm.

**A TLA+ model** (`spec/tla/`), checked exhaustively with TLC:

- `ORMapMerge.tla` transcribes the per-key merge behind
  `barrel_p2p_ormap:merge/2`, clause for clause.
- `MergeLattice.tla` checks every combination of entries over a small dot
  universe: merge is commutative and idempotent, and associative for
  everything a read or a later merge can observe.
- `ReplicaORMap.tla` models `barrel_p2p_replica` as coded: each node's
  OR-Map, its HLC, and the queue of broadcasts its replica process has
  not handled yet. It covers Plumtree deltas (relayed, lost when no path
  exists), direct full-sync snapshots, `peer_up` and `peer_down` with
  pruning, anti-entropy, and a final heal.

**A PropEr simulation**
(`test/barrel_p2p_replica_convergence_prop_tests.erl`) runs random
operation, delivery, loss and partition sequences over the real
`barrel_p2p_ormap` code, and replays the TLA+ counterexamples.

## Properties

| Property | Meaning |
|---|---|
| `QuiescentConverged` | Once the network heals and traffic stops, every node shows the same map. |
| `WriterIntentKept` | A key with one writer ends where that writer left it, on every node. A removed key stays removed. |
| `NoResurrection` | A node never shows a value older than a tombstone it holds or held for that key. |

## Model configurations

| Model | Consumer | Result |
|---|---|---|
| `MC_registry` | registry, leader (one writer per key, no anti-entropy, prune on `peer_down`) | passes, 207,734 states |
| `MC_map` | `barrel_p2p_map` (several writers, anti-entropy) | passes, 574,617 states |
| `MC_map_partition` | `barrel_p2p_map`, full partition | passes, 945,960 states |
| `*_stamp`, `*_snap` | the 0.1.x code, one bug each | fail, see below |

## Bugs the model found

Both are fixed. The failing configurations stay in the suite to show the
model detects them.

- **Double stamp.** A writer stored its write with one HLC, then
  `broadcast_update/2` gossiped it with a second, later one. After a
  partition, the writer's full sync repaired peers with its older stored
  copy, which lost to the gossiped one. A removed registration stayed
  visible on a peer, and a removed map key came back on every node. Writers
  now gossip the stored entry with `broadcast_entry/3`.
- **Tombstone-only snapshots.** `replica_full_sync_snapshot/1` returned
  `empty` for a map holding only tombstones, so a peer that missed a
  remove during a partition was never told. For reminders, a missed fire
  or cancel could make the reminder fire again. Snapshots are now sent
  whenever the map is non-empty.

## Limits

- **Small bounds.** Three nodes, one key, up to three writes, up to two
  link failures. Bugs that need more nodes or more writes to show up are
  not excluded.
- **Abstractions.** An HLC is a natural number. A Plumtree delta reaches
  any node within one relay hop. `crdt_wire` validation is assumed to
  accept everything.
- **Tombstone GC** (`gc_tombstones/2`) is not modelled. Its safety rests
  on the cutoff rule in its doc comment.
- **Strict associativity.** It does not hold: a tombstone that beats a
  value drops that value's dots, so two replicas can hold different dot
  sets for the same visible value. No merge decision or read can see the
  difference. Only `barrel_p2p_map`'s `prune_on_peer_down`, which reads
  the full dot set, could prune differently.
- **Not modelled yet:** leader election fencing, Plumtree itself,
  HyParView, and the Ed25519 handshake.

To run the checker, see [Run the model checker](../how-to/run-the-model-checker.md).
