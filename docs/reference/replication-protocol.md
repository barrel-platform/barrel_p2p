# Replication protocol

This page specifies the protocol behind barrel_p2p's replicated services:
the service registry, leader election, durable reminders and replicated
maps. It covers the data each node holds, the messages nodes exchange, what
each node does on each event, and what the protocol guarantees. Read it when
you implement a `barrel_p2p_replica` consumer, debug a convergence problem,
or review a change to replication. For the API, see
[Replicated substrate](replicated-substrate.md). For what is proven, see
[Verification](../concepts/verification.md).

## Overview

Each replicated service is an **instance**: an owner process that holds an
OR-Map, and a `barrel_p2p_replica` process that moves deltas and snapshots
between nodes. Instances are independent. They share the membership and
broadcast layers below them.

| Layer | Module | Role |
|---|---|---|
| Membership | `barrel_p2p_hyparview` | Keeps a small active view of connected peers; emits `peer_up` and `peer_down`. |
| Broadcast | `barrel_p2p_plumtree` | Delivers a payload to every node reachable through active views, including the sender. |
| Replication | `barrel_p2p_replica` | Gossips deltas, runs full syncs and anti-entropy, prunes on `peer_down`. |
| State | `barrel_p2p_ormap` | Last-write-wins map with tombstones; the merge every node applies. |
| Time | `barrel_p2p_hlc` | Hybrid logical clock that stamps every write. |

The protocol is AP: there is no leader and no consensus. Every node accepts
writes, and replicas converge once they have received the same writes.

## State

### Timestamps

A timestamp is a hybrid logical clock value `#timestamp{wall_time, logical}`
(Kulkarni et al. 2014). Timestamps are totally ordered: `wall_time` first,
then `logical`. Each node runs one clock (`barrel_p2p_hlc`) shared by every
instance on that node.

- `now()` returns a timestamp greater than every timestamp the node has
  issued or absorbed.
- `update(T)` absorbs a received timestamp, so a later `now()` is greater
  than `T`.

### Dots

A dot `{Node, Timestamp}` names one write. Dots are totally ordered by
timestamp, then by node name. The node tiebreak makes two writes stamped in
the same millisecond resolve the same way on every node.

### Entries

An OR-Map maps each key to one entry:

| Entry | Meaning |
|---|---|
| `{value, V, #{Dot => true}}` | `V` was written by the write `Dot`, the newest write seen for the key. |
| `{tombstone, T}` | The key was removed at `T`. |

A value carries exactly one dot. Entries from 0.1.x nodes may carry several
dots; they are reduced to the newest one when merged.

### Merge

`merge/2` merges two maps key by key. For each key present in both:

| Local | Incoming | Result |
|---|---|---|
| value, dot `D1` | value, dot `D2` | the value with the greater dot |
| tombstone `T1` | tombstone `T2` | the greater tombstone |
| tombstone `T` | value, dot `D` | the tombstone if `T` is greater than `D`'s timestamp, else the value |

A key present on one side only is kept as is. A value wins a tie with a
tombstone. Merge is commutative, associative and idempotent, so the order,
grouping and repetition of deliveries do not change the result
(Shapiro et al. 2011).

## Messages

Instance `Name` is both the registered process name and the broadcast tag.

| Message | Transport | Sent when |
|---|---|---|
| `{delta, FromNode, Delta}` | Plumtree, tag `Name` | A local write. `Delta` is `#{Key => Entry}`. |
| `{custom, FromNode, Payload}` | Plumtree, tag `Name` | `broadcast_custom/2` (leader fencing tokens). |
| `{'$barrel_p2p_replica', {full_sync, FromNode, Snapshot}}` | direct, to `{Name, Node}` | `peer_up`, or a `request_sync` received. |
| `{'$barrel_p2p_replica', {request_sync, FromNode}}` | direct, to `{Name, Node}` | Start, source restart, anti-entropy. |

Direct messages are sent with `noconnect`: they only reach nodes that
already have a distribution channel. Plumtree carries deltas as
`{'$barrel_p2p_plumtree', {gossip, MsgId, Tag, Payload, Origin}}` to eager
peers and `{ihave, MsgId, Node}` to lazy peers. A node that sees `ihave`
for a message it lacks sends `graft` after one second, and a node that gets
a duplicate replies `prune` (Leitão et al. 2007b). Plumtree remembers a
message id for five minutes.

Every received entry passes `barrel_p2p_crdt_wire` validation before it
reaches the clock or the merge. Invalid entries are dropped, the rest of
the message is kept.

## Procedures

### Local write

1. The owner applies the write to its OR-Map: `add/3` stamps a new dot
   with `now()`, `remove/2` writes a tombstone at `now()`.
2. The owner calls `broadcast_entry(Name, Key, Map)`. The replica process
   gossips the entry exactly as stored.

Both steps must use the same stored entry. A stamp minted later, as
`broadcast_update/2` does, can make the writer's own copy older than the
copy its peers hold (see [Verification](../concepts/verification.md)).

### Receiving a delta or a snapshot

1. Validate the entries.
2. Absorb every accepted timestamp into the local clock (`update/1`).
3. Merge the accepted entries into the owner's map.
4. Update read projections (ETS) and emit events for the changed keys.

Plumtree also delivers a node's own deltas back to it. Consumers that merge
deltas into the map they write (map, leader, reminder) treat this as a
no-op merge.

### `peer_up`

The replica adds the peer to its peer set and sends it a `full_sync` with
`replica_full_sync_snapshot/1`. A snapshot is sent unless the map has no
entries at all. Tombstones count: a peer that missed a remove learns it only
here.

### `peer_down`

The replica removes the peer from its peer set and calls
`replica_remove_node/2`. What that drops is the consumer's choice (see the
table below). A prune is local: it deletes entries without tombstones, so a
later full sync from a node that still holds them brings them back.

### Start and source restart

On start, the replica seeds its peer set from the current active view and
sends `request_sync` to each peer. It does the same after the Plumtree or
membership process restarts, to recover deltas missed in the gap.

### Anti-entropy

A consumer that exports `replica_anti_entropy/0` returning `true` sends
`request_sync` to one random peer every `replica_anti_entropy_ms` (default
30 s, jittered by ±25%). This repairs nodes whose link survived a
partition and so never saw a fresh `peer_up` (Demers et al. 1987).

### Tombstone GC

Map and reminder owners drop tombstones older than their TTL (default one
hour) on a periodic scan. GC is safe only if no add older than the dropped
tombstone can still arrive, so the TTL must exceed the longest partition
you expect to heal from.

## Consumers

| Service | Writers per key | Snapshot holds | Own deltas merged into written map | Prune on `peer_down` | Anti-entropy |
|---|---|---|---|---|---|
| Registry | one (`{Name, node()}`) | own registrations | no (kept in a remote cache) | keys of the departed node | no |
| Leader election | one (`{Name, node()}`) | all candidates and fences | yes | keys of the departed node | no |
| Reminders | any | all reminders | yes | nothing | yes |
| Replicated map | any | all entries | yes | keys whose latest write came from the departed node, if `prune_on_peer_down` | yes |
| Sharded placement | one (`node()`) | wall-clock leases | n/a (no OR-Map copy) | nothing (leases expire) | no |

## Guarantees

- **Convergence.** Once the network heals, queued broadcasts are sent and
  full syncs have run, every node holds the same map. Within the model's
  bounds this is checked by TLC for the registry, leader and map
  configurations.
- **Removes stick.** A key with a single writer ends where that writer left
  it on every node. A delayed add older than a tombstone never resurrects
  the key.
- **Last write wins.** Concurrent writes to one key from different nodes
  keep the one with the greater dot. The other is lost, not merged.
- **Clock skew.** A node whose clock runs ahead wins concurrent writes until
  real time catches up. HLC bounds the drift it introduces but does not
  remove it.
- **No ordering across keys.** Writes to different keys can arrive in any
  order.
- **No read-your-writes on other nodes.** A write is visible locally at
  once and elsewhere after gossip.

## Compatibility

A 0.1.x node gossips values with every dot that wrote them, and may gossip
a stamp newer than its own stored copy. Current nodes reduce incoming values
to their newest dot on merge, and TLC checks that merge stays commutative
and associative across both kinds of entries. Upgrade every node to get the
fixed resync behaviour.

## References

Full citations are on the [References](references.md) page: HyParView and
Plumtree (Leitão et al. 2007), anti-entropy (Demers et al. 1987), hybrid
logical clocks (Kulkarni et al. 2014), CRDTs (Shapiro et al. 2011),
last-write-wins (Johnson and Thomas 1975), and TLA+ (Lamport 2002).
