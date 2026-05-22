# Sharded placement

Sharded placement answers one question: **given a key, which node
should own it?** Every node computes the same answer, so you can
partition state across the cluster (caches, in-memory shards, work
queues) and route a key to its owner from anywhere.

The service registry tells you where a process is registered today.
Placement tells you where a key *should* live, which is what you need
to spread state evenly and to know who takes over a key when a node
leaves. This page covers the membership model, the hash ring, and the
ownership events you react to on churn.

## The live-node set

Placement needs every node to agree on the set of members, or the ring
diverges. Mycelium does not keep a full cluster roster in HyParView
(the active and passive views are bounded, per-node, partial), so the
shard builds its own **replicated, lease-based live-node set**:

- Each node gossips a small heartbeat carrying its wall-clock time,
  every `member_heartbeat_ms`.
- A node is "in the ring" while its lease is fresh, that is while
  `Now - EmitTime =< member_ttl_ms`.
- Heartbeats whose timestamp is too far in the future (more than
  `member_skew_ms` ahead) are rejected, so a node with a fast clock
  cannot keep a dead node alive.

This is deliberately NOT driven by HyParView `peer_down`. A peer
leaving your active view is topology churn, not cluster death; the
node may still be alive and reachable through the overlay. Liveness is
decided by the lease alone, so the answer is the same on every node.

Because liveness is a timestamp, the set converges without tombstones:
a stale entry that arrives in a full-sync is simply already expired,
and a node that comes back starts heartbeating again. Expired entries
are swept locally so the set stays bounded.

Agreement is **eventual**. After a join, a leave, or a crash, nodes
converge once heartbeats and sweeps have propagated; during that window
they can briefly disagree on an owner. That is the same trade every
other eventually-consistent piece of mycelium makes.

## The hash ring

Ownership uses **rendezvous hashing** (HRW, highest random weight) over
the live set, bucketed into `ring_size` partitions:

```
partition(Key) = phash2(Key, ring_size)
owner(P)       = the node maximizing {phash2({Node, P}), Node}
place(Key)     = owner(partition(Key))
```

Two properties make this the right fit:

- **Minimal disruption.** When a node joins, it only takes the
  partitions that now hash highest to it. When a node leaves, only the
  partitions it owned move, and they spread across the remaining nodes.
  Ownership of every other partition is unchanged. No global reshuffle.
- **Deterministic.** The trailing `Node` in `{Score, Node}` is an
  explicit tie-breaker: `phash2` has a finite range and can collide, so
  ownership must not depend on map or set traversal order. Given the
  same member set, every node computes the identical ring.

`ring_size` (default 64) is the granularity of ownership events. It
**must be identical on every node**: a node running a different
`ring_size` computes a different `partition/1` and `place/1` and will
diverge. Treat it, and the lease timings, as cluster-wide settings.

## Placing keys

```erlang
mycelium:place(Key).        %% node() that should own Key
mycelium:is_owner(Key).     %% am I that node?
mycelium:owners(Key, 3).    %% top-3 distinct nodes, for replicated placement
mycelium:partition(Key).    %% 0..ring_size-1 bucket Key falls in
mycelium:members().         %% the current live set (sorted)
```

`place/1` and friends are lock-free reads off a hot path: the shard
publishes the live member list to an ETS table and these functions
compute the answer locally, with no `gen_server` round trip.

`owners/2` returns the N best nodes for a key. Use it when you keep a
key on more than one node (a primary plus replicas): write to all N,
read from the first reachable.

## Reacting to churn

Owning a partition usually means holding state for it. When the ring
changes you need to take over the partitions you gained and release the
ones you lost. Subscribe and react:

```erlang
init(_) ->
    ok = mycelium:subscribe_shard(),
    {ok, #{}}.

handle_info({mycelium_shard, {acquired, P}}, S) ->
    %% This node now owns partition P: load / take over its state.
    {noreply, take_over(P, S)};
handle_info({mycelium_shard, {released, P}}, S) ->
    %% This node no longer owns P: stop serving / hand off its state.
    {noreply, hand_off(P, S)}.
```

Map your keys to partitions with `mycelium:partition(Key)` so you know
which keys an `{acquired, P}` / `{released, P}` event covers.

Events fire only when the live set actually changes, not on every
heartbeat. During churn you may briefly own a partition on two nodes
before the set converges, so make take-over and hand-off idempotent.

## Configuration

| Key                   | Default | Meaning                                         |
|-----------------------|---------|-------------------------------------------------|
| `ring_size`           | 64      | Partition count. Must match on every node.      |
| `member_heartbeat_ms` | 2000    | How often a node re-announces itself.           |
| `member_ttl_ms`       | 6000    | Lease lifetime; a node drops after this.        |
| `member_skew_ms`      | 5000    | Reject heartbeats this far in the future.       |

`member_ttl_ms` should comfortably exceed `member_heartbeat_ms` plus
the expected clock skew between nodes, so a live node is never swept
between beats.

## Related

- [Gossip broadcast](gossip-broadcast.md) carries the heartbeats and
  full-syncs the member set on `peer_up`.
- [Leader election](leader-election.md) is the "exactly one" cousin;
  placement is "one of N, by key".
- [Cluster membership](cluster-membership.md) is the HyParView overlay
  the heartbeats travel over.
