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
  universe: merge is commutative, associative and idempotent. Entries from
  0.1.x nodes, which carry several dots, are checked too, so a cluster
  running both versions still converges.
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
| `MC_registry` | registry (one writer per key, snapshots of its own keys, deltas kept in a separate remote cache, prune on `peer_down`) | passes, 189,802 states |
| `MC_leader` | leader election (one writer per key, snapshots of all candidates, prune on `peer_down`) | passes, 456,930 states |
| `MC_map` | `barrel_p2p_map` and reminders (several writers, anti-entropy) | passes, 437,577 states |
| `MC_map_partition` | `barrel_p2p_map`, full partition | passes, 592,470 states |
| `*_stamp`, `*_snap` | the 0.1.x code, one bug each | see below |

## Bugs the model found

All are fixed. The failing configurations stay in the suite to show the
model detects them.

- **Double stamp** (registry). A writer stored its write with one HLC,
  then `broadcast_update/2` gossiped it with a second, later one. The
  registry keeps its own writes apart from the deltas it receives, and
  snapshots only its own writes. So after a partition its full sync
  repaired peers with the older stored copy, which lost to the gossiped
  one: an unregistered service stayed listed on a peer
  (`MC_registry_stamp` fails). The map, leader election and reminders
  merge their own deltas back into the map they write, which replaced the
  stale stamp a moment later; the model confirms they were not exposed
  (`MC_leader_stamp` and `MC_map_partition_stamp` pass). Writers now
  gossip the stored entry with `broadcast_entry/3`, which removes the
  window for everyone.
- **Tombstone-only snapshots** (all four services). `replica_full_sync_snapshot/1`
  returned `empty` for a map holding only tombstones, so a peer that
  missed a remove during a partition was never told (`MC_registry_snap`,
  `MC_leader_snap` and `MC_map_snap` fail). For reminders, a missed fire
  or cancel could make the reminder fire again. Snapshots are now sent
  whenever the map is non-empty.
- **Non-associative merge.** A value kept every dot that had written it,
  and a tombstone that beat a value dropped them, so two replicas could
  hold different dot sets for the same value. A value now keeps only its
  newest dot, which makes merge strictly associative.

## Membership

`spec/tla/HyParView.tla` models `barrel_p2p_hyparview` and the bridge
as coded: dist channels separate from the views, `noconnect` sends
lost without a channel, one ordered inbox per node for the bridge's
reports and arriving messages, and the event stream Plumtree and the
replicas consume.

| Property | Meaning |
|---|---|
| `SymmetricAtQuiescence` | Once messages settle, B is in A's active view exactly when A is in B's. |
| `EventsMatchView` | Subscribers' view, folded from `peer_up` and `peer_down`, equals the active view. |
| `ConnectedAtQuiescence` | Without faults, every node can reach every other through active links. |
| `LeftStaysOut` | A node that called `leave/0` holds no active links until it joins again. |
| `ViewBounds`, `NoSelf` | Views stay within their sizes and never hold the node itself. |

| Model | Setting | Result |
|---|---|---|
| `MC_hyparview` | 3 nodes, one fault (failed dial, channel drop, crash, leave or 30 s stall), rejoin after leave | passes, 80,927 states |
| `MC_hyparview4` | 4 nodes, active views of 2, so joins evict | passes, 781,528 states |
| `MC_hyparview_link` | the 0.1.x forward-join | fails `SymmetricAtQuiescence` |
| `MC_hyparview_leave` | the 0.1.x leave | fails `EventsMatchView` |
| `MC_hyparview_rejoin` | the 0.1.x handling of a node that left | fails `LeftStaysOut` |

Defects found, all fixed:

- **One-sided links.** A node accepting a forward-join dialed the
  new peer and added it, but the new peer's bridge does not report
  a channel it did not ask for, so the new peer never added the
  link. The dialer now sends a high-priority `NEIGHBOR`.
- **Leave without events.** `leave/0` cleared the views without
  `peer_down`, so Plumtree kept gossiping to peers the node had
  left.
- **Pulled back after leave.** A peer receiving the leaving node's
  `DISCONNECT` kept it as a spare, promoted it at once, and the
  node, still running, accepted. A node that left now refuses
  `NEIGHBOR`, answers `JOIN` with `DISCONNECT`, and ignores
  `FORWARD_JOIN` and connection reports until it joins again.
- **Crossing and late replies.** Several races left a link on one
  side: a refusal arriving from a peer that had meanwhile become a
  neighbor through another request, a late acceptance for a peer
  evicted since or whose request timed out, and a connection report
  for a dial the node no longer tracked. The rules now are:
  - a request from a peer that is already active is accepted;
  - an acceptance counts only for a request the node is tracking;
  - an unexpected acceptance from a peer that is not active gets a
    `DISCONNECT`, and the peer is kept as a spare;
  - a refusal from a peer that is active anyway only clears the
    request;
  - an untracked connection report is ignored.
- Found while modelling, outside the invariants:
  - promoting a passive peer crashed the server as soon as the dial
    succeeded (an unmatched `neighbor` pending entry);
  - `NEIGHBOR` was sent before the dial, so it was lost when no
    channel existed yet;
  - neighbor links emitted no `peer_up`;
  - a failed or refused promotion candidate vanished instead of
    backing off (a refused one was asked again at once);
  - `last_seen` mixed time units, so passive entries never aged out.

The model leaves out shuffle (it only refreshes passive views) and
picks evictions, forward targets and promotion candidates
nondeterministically, a superset of what the code does at random.
`test/barrel_p2p_hyparview_e2e_SUITE.erl` checks symmetry and
connectivity on five real nodes, before and after one dies.

## Broadcast

`spec/tla/Plumtree.tla` models `barrel_p2p_plumtree` for two
broadcasts from one origin over a 4-node overlay with a chord. The
first broadcast trims the tree (`PRUNE` turns links lazy), so the
second depends on `IHAVE` / `GRAFT` repair. Links can be evicted (the
channel stays up and in-flight messages still arrive) or fail (the
channel and its messages go).

| Property | Meaning |
|---|---|
| `DeliveredAtQuiescence` | Once nothing is in flight, every node still linked to the origin delivered the second message. |
| `EagerInView` | Plumtree pushes eagerly only to peers in the HyParView view. |

| Model | Setting | Result |
|---|---|---|
| `MC_plumtree` | up to 2 link faults | passes, 3,787,344 states |
| `MC_plumtree_graft` | the 0.1.x announcer handling | fails `DeliveredAtQuiescence` |
| `MC_plumtree_eager` | the 0.1.x eager handling | fails `EagerInView` |
| `MC_plumtree_drop` | the 0.1.x `nosuspend` sends | fails `DeliveredAtQuiescence` |

Defects found, all fixed:

- **One announcer, one graft.** A node remembered only the first peer
  that announced a missing message and grafted it once. When that
  peer's link failed, the message was never fetched from the other
  peers that had announced it.
- **Silent drops.** Sends used `nosuspend` and ignored the result, so a
  busy channel dropped messages with no failure to react to.
- **Stale eager peers.** A `GOSSIP` or `GRAFT` arriving after a peer
  left the view made it eager again, and the node kept pushing to it.

Recovery of messages broadcast during a partition is out of scope:
Plumtree does not replay them, and the replicated services resync
instead (see [Gossip broadcast](gossip-broadcast.md)).

## Leader election

`spec/tla/Leader.tla` models `barrel_p2p_leader` for one election
name, over the replica layer reduced to what it guarantees (every
node eventually sees each candidate add and remove, and a remove wins).

| Property | Meaning |
|---|---|
| `AgreementAtQuiescence` | Once gossip settles, every node knows the same candidates, so they compute the same leader. |
| `LeaderHoldsMaxFence` | The agreed leader holds the highest fence ever minted, so a fenced resource accepts its writes. |

| Model | Setting | Result |
|---|---|---|
| `MC_leader_election` | 2 candidates campaigning concurrently | passes, 4,927 states |
| `MC_leader_fence` | the 0.1.x fencing | fails `LeaderHoldsMaxFence` |

Defect found, fixed: when two nodes campaigned at once, the one that
had not yet heard of the other could mint a higher fence while it
briefly believed it led. The real leader only raised its high-water
mark and kept its lower token, so a resource that had accepted the
higher one refused the leader for good. A leader that learns a higher
fence now mints above it and sends `{elected, Fence}` again.

While both still believe they lead, they re-mint above each other
until the candidate updates arrive (one gossip round). The model
bounds this with a constraint, and checks two nodes: three did not
fit in the time budget.

## Authentication

`spec/tamarin/` models the distribution auth handshake in Tamarin,
against an attacker who controls the network, can register names
with its own keys, and can steal node keys.

| Lemma | Meaning | v2 (0.1.x) | v3 |
|---|---|---|---|
| `client_authenticates_target` | The client ends up authenticated to the node it dialed. | falsified | verified |
| `client_agreement` | An accepted server really ran this handshake. | falsified (role confusion) | verified |
| `server_agreement` | An accepted client really ran this handshake with this server. | falsified (reflection) | verified |
| `client_injective_agreement` | Each accepted handshake matches its own server run. | | verified |
| `dist_name_is_authenticated` | The Erlang dist name is the authenticated name. | falsified | verified, given the quic check |

Three attacks on v2 come out of the model:

- **Name substitution.** Nothing compared the authenticated name
  with the dialed node or with the dist name. Anyone holding a key
  the cluster accepts for one name could connect as another node.
- **Reflection.** Signatures carried no role, and a server signs
  the client's challenge before verifying the client. An attacker
  could open two connections to a node and make it sign its own
  challenge, then be accepted as that node.
- **Role confusion.** For the same reason, a signature a node made
  as a client passed as its server response. An attacker running
  one TLS endpoint could get node N to connect to it and sign a
  challenge taken from a client that reached the same endpoint
  while looking for N. The client then accepted the attacker as N.
  The certificate binding does not help: both legs end at the
  attacker's certificate.

v3 signs the full transcript with a role label, and the client
checks the authenticated name against the dialed node.
`dist_name_is_authenticated` relies on `quic_dist` refusing a dist
name that differs from the authenticated one. Until barrel_p2p
depends on a quic release that does this, the server side of that
lemma does not hold in the code.

The model leaves out timestamps (freshness comes from the nonces),
the cookie-only path, and TLS beyond the certificate hash.

## Limits

- **Small bounds.** Three nodes, one key, up to three writes, up to two
  link failures. Bugs that need more nodes or more writes to show up are
  not excluded.
- **Abstractions.** An HLC is a natural number. A Plumtree delta reaches
  any node within one relay hop, and reaches its sender at once. `crdt_wire` validation is assumed to
  accept everything.
- **Tombstone GC** (`gc_tombstones/2`) is not modelled. Its safety rests
  on the cutoff rule in its doc comment.
- **Not modelled yet:** reminders and tombstone GC.

The protocol the model describes is specified in [Replication
protocol](../reference/replication-protocol.md), and the literature it
builds on is on the [References](../reference/references.md) page. To run
the checker, see [Run the model checker](../how-to/run-the-model-checker.md).
