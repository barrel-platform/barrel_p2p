# Gossip broadcast

The protocol that moves registry updates and other cluster
gossip across the network is Plumtree (Push-Lazy-Push Multicast
Tree). It produces an efficient broadcast tree that self-heals
under churn.

This page explains the algorithm and the invariants it
maintains.

## The problem

Naive epidemic gossip floods. Every node retransmits every
message it sees to every neighbour, generating O(n²) wire
traffic. The cluster converges, but the cost grows quadratically
with size.

Plumtree replaces the flood with a *spanning tree* that
self-organises out of the active-view links. Once the tree is
stable, each broadcast costs O(n) messages: one per node, not
one per pair.

The clever bit is that the tree heals automatically when peers
fail: there is no separate maintenance pass.

## The algorithm

Each node classifies its [active-view](cluster-membership.md)
peers into two sets:

- **Eager peers** receive the full body of every broadcast.
- **Lazy peers** receive only an `IHAVE` announcement
  (essentially the message ID and the sender).

The split starts trivially: when a node first joins, all of its
active peers are eager. From then on, the protocol re-shapes
the sets as broadcasts flow:

- A *duplicate* arrival (you already have the body, somebody
  sent it again) triggers a `PRUNE`: the sender becomes lazy
  for you. The next broadcast they originate, they will
  announce to you via `IHAVE` rather than push directly.
- A *missing message* (you received an `IHAVE` but never the
  body) triggers a `GRAFT`: the lazy peer is promoted back to
  eager, and they retransmit the message.

In the steady state, each broadcast flows down a single
spanning tree of eager links. Lazy links act as a backup index;
when the tree breaks, `GRAFT` repairs it.

## Protocol messages

```
GOSSIP(MsgId, Payload, Round)         %% full body, push
IHAVE(MsgId, Round)                   %% announcement, lazy
GRAFT(MsgId)                          %% "promote me to eager"
PRUNE                                 %% "demote me to lazy"
```

`Round` is a counter on broadcasts; it lets a receiver detect
out-of-order delivery and decide when to give up waiting for a
graft.

## Visualising a broadcast

A single broadcast through a six-node cluster, after the tree
has stabilised:

```
        origin
         /  \
        v    v
     peerA  peerB
      / \     \
     v   v     v
   peerC peerD peerE
                |
                v
              peerF
```

Solid edges (`->`) are eager. Every peer receives the body
exactly once.

A peer that fails (say, `peerD` disconnects) removes its slice
of the tree. The next broadcast from `peerA` propagates to
`peerC` only. `peerE` and `peerF` still receive via the
right-hand branch through `peerB`. The lazy backups will
re-graft `peerC` to one of `peerE`'s parents if needed.

## Why this is efficient

For a cluster of `n` nodes:

- A naïve flood sends `O(n²)` messages per broadcast.
- Plumtree sends `O(n)` `GOSSIP` messages (one per node) plus
  `O(n)` `IHAVE` messages (one per lazy edge), in the steady
  state.
- Repair messages (`GRAFT` / `PRUNE`) are bounded by the rate
  of churn; on a healthy cluster they are rare.

The protocol scales gracefully with cluster size and tolerates
peer failures without a separate repair pass.

## When the tree breaks

Two failure modes are interesting:

- **A peer crashes mid-broadcast.** The next-hop peers receive
  the message via the eager edge only if the crash happened
  *after* the body was sent. If not, they will see the
  `IHAVE` from a lazy peer and `GRAFT` to recover. Total
  recovery time is bounded by one round-trip plus the
  retransmit.
- **A network partition splits the active view.** Plumtree
  keeps broadcasting on each side; when the partition heals,
  the next broadcast picks up missed messages through
  `GRAFT`. Older messages (past `MESSAGE_TTL`, default 5
  minutes) are dropped: the system is eventually consistent,
  not infinitely retentive.

## Message deduplication

Each peer maintains a small ETS-backed cache of recently-seen
message IDs. On each `GOSSIP` arrival, the cache is checked
first; duplicates trigger `PRUNE` and are dropped from the
broadcast path.

The cache has a TTL (`MESSAGE_TTL`, 5 minutes); entries past
that age are discarded. Past the TTL, a re-broadcast of an old
message would be re-flooded as if new. This is intentional: it
bounds memory.

## Observability

Plumtree exposes a small set of metrics. The interesting ratios:

| Metric | Healthy ratio |
|--------|---------------|
| `barrel_p2p.plumtree.graft.sent` / `gossip.received` | Should be small. A high ratio means lots of self-healing, which is a symptom of churn in the active view. |
| `barrel_p2p.plumtree.prune.sent` / `gossip.received` | A non-trivial steady-state value is normal (the tree settling). A spike means the tree is reshaping (peer failures, joins). |
| `barrel_p2p.plumtree.ihave.sent` | Roughly tracks active-view size × broadcast rate. |

See [observe a cluster](../how-to/observe-cluster.md) for the
full catalogue.

## Configuration

There are no operator-tunable Plumtree knobs in barrel_p2p today.
The defaults match the HyParView paper. If you want to tweak the
deduplication TTL or the graft timeout, the constants live in
`src/barrel_p2p_plumtree.erl`.

## API

Plumtree is internal; you do not call it directly. The
subsystems that use it (the [service registry](service-registry.md),
service-event broadcasts) are the consumers.

If you want to broadcast your own message:

```erlang
barrel_p2p_plumtree:broadcast(Tag, Payload).

%% Subscribe to receive broadcasts.
barrel_p2p_plumtree:subscribe(self()).
%% Receives: {plumtree_broadcast, {Tag, Payload}}
barrel_p2p_plumtree:unsubscribe(self()).
```

The API is `beta` — the calling shape may change across minor
bumps. For application-level pub/sub, prefer building on
top of the service registry's events; for large blobs, use the
tagged-stream multiplex ([streams concept](streams.md)).

## Related

- [Cluster membership](cluster-membership.md) is what produces
  the active-view links Plumtree builds the tree on top of.
- [Service registry](service-registry.md) is the main consumer
  of Plumtree broadcasts inside barrel_p2p.
- [Observe a cluster](../how-to/observe-cluster.md) lists the
  metrics emitted by the gossip layer.
