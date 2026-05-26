# Cluster membership

Barrel P2P does not maintain a full mesh. Each node keeps a small,
bounded set of *gossip peers*; the cluster as a whole remains
reachable through OTP's demand-driven dist auto-connect. The
membership protocol that keeps the gossip topology coherent is
HyParView.

This page explains the protocol from a developer's point of view:
the two views it maintains, how a node joins, how failures are
handled, and how the picture is kept fresh.

## The two views

Every node maintains two ordered sets of peers:

- The **active view** is the small bounded set (default size 5)
  of peers this node currently exchanges gossip with. The links
  are symmetric: if A has B in its active view, B has A in its
  active view. The size is `active_size` in sys.config.
- The **passive view** is a larger bounded cache (default size
  30) of *known* peers that this node is not currently
  connected to. The passive view is a reserve: when an active
  link drops, a passive peer is promoted to replace it. The
  size is `passive_size`.

![HyParView active view: a node connects to a small set of gossip peers, with additional known peers held in a passive cache.](diagrams/active-view.png)

The crucial property: the active view does **not** need to grow
with the cluster. A node with a thousand peers in its passive
view still keeps only five active links. The protocol guarantees
that any peer is reachable from any starting point by repeatedly
forwarding through these small bounded views.

## Joining the cluster

When a new node joins, it sends a `JOIN` message to one *contact
node* it knows about. The contact node is either named explicitly
via `barrel_p2p:join/1` or configured in sys.config:

```erlang
{barrel_p2p, [
    {contact_nodes, ['seed1@host', 'seed2@host']}
]}.
```

The protocol flow:

```
NewNode ----JOIN----> ContactNode
                            |
                            +-- adds NewNode to its active view
                            |
                            +-- sends FORWARD_JOIN(TTL=ARWL) to a
                                random active peer (which forwards
                                again, until TTL=0)
```

Forwarding has two purposes:

- Knowledge of the new node spreads beyond the contact node.
- Each receiving node either adds the new node to its own
  active view (small probability, decreasing with TTL) or to
  its passive view (at TTL=0). The passive entry is a warm
  spare for future use.

The TTL is the *active random walk length* (`arwl`, default 6).
A smaller value confines the join to the contact node's
neighbourhood; a larger value spreads the new node more widely
at the cost of more messages.

## Failure handling

A peer failure is detected through the dist channel:
`net_kernel` reports a `nodedown` event, barrel_p2p translates it
into a HyParView failure, and the protocol takes over:

1. The failed peer is moved from active to a transient
   "failed" state with an exponential backoff timer.
2. After `max_fail_count` consecutive failures (default 5), the
   peer is moved out of the active view entirely and into the
   passive view.
3. A replacement is picked from the passive view and sent a
   `NEIGHBOR` request. If the candidate accepts, the active
   view is back to its target size.

Backoff prevents reconnection storms during network partitions.
If half the cluster becomes unreachable at once, each surviving
node retries its neighbours on staggered timers rather than
simultaneously.

## Shuffle: keeping passive views fresh

Every `shuffle_period` ms (default 10s), a node picks a random
active peer and exchanges a small sample of its active and
passive views. This is how:

- A node learns about peers that joined after it did and that
  the contact-node `FORWARD_JOIN` did not reach.
- The passive view stays fresh enough that there is always a
  spare to replace a failed active peer.

The exchange is bounded: a fixed-size random sample
(`shuffle_length`, default 8), never the full views.

## Active view eviction

When the active view is full and a new peer wants to enter (via
`JOIN` or `NEIGHBOR`), the protocol evicts an existing active
peer to make room. The evicted peer goes to the passive view; the
HyParView-level connection (a `disconnect` protocol message) is
sent so the peer learns we no longer treat it as gossip-active.

The dist channel between us and the evicted peer stays up. The
peer is still reachable for `Pid ! Msg`; it just is not in the
gossip topology any more. The idle dist GC will eventually reap
the channel if no traffic flows over it.

## The relationship with `erlang:nodes/0`

Two important calls return different things:

- `barrel_p2p:active_view/0` returns the small HyParView gossip
  topology. It is bounded by `active_size`. This is the set
  used for gossip and for the broadcast tree.
- `erlang:nodes/0` returns every node this BEAM currently has a
  dist channel with. It includes the active view and any
  on-demand channels opened by `Pid ! Msg`.

The two sets can differ. After a `Pid ! Msg` to a peer outside
the active view, that peer appears in `erlang:nodes/0` but not
in `barrel_p2p:active_view/0`. Once the idle GC reaps the channel,
it disappears from `erlang:nodes/0` too.

## Configuration knobs

| Key | Default | Purpose |
|-----|---------|---------|
| `active_size` | 5 | Maximum concurrent gossip peers. |
| `passive_size` | 30 | Maximum known-but-disconnected peers. |
| `arwl` | 6 | Active random walk length (join propagation TTL). |
| `prwl` | 3 | Passive random walk length (when a forward-join lands in passive). |
| `shuffle_length` | 8 | Peers exchanged per shuffle round. |
| `shuffle_period` | 10000 ms | Time between shuffle rounds. |
| `max_fail_count` | 5 | Failures before a peer is demoted to passive. |
| `base_backoff_ms` | 1000 | Initial backoff after a failure (doubles up to 5 min). |
| `passive_max_age_ms` | 300000 | Maximum age before a passive entry is dropped. |

For sizing recommendations by cluster size, see
[run in production](../how-to/run-in-production.md).

## API

The relevant entry points in `barrel_p2p.erl`:

```erlang
barrel_p2p:join(ContactNode) -> ok | {error, term()}.
barrel_p2p:leave() -> ok.
barrel_p2p:active_view() -> [node()].
barrel_p2p:passive_view() -> [node()].

%% Subscribe to membership transitions.
barrel_p2p:subscribe() -> ok.
barrel_p2p:subscribe(Pid) -> ok.
barrel_p2p:unsubscribe(Pid) -> ok.

%% Events delivered as:
%%   {barrel_p2p_event, {peer_up, Node}}
%%   {barrel_p2p_event, {peer_down, Node, Reason}}
%%   {barrel_p2p_event, joined}
%%   {barrel_p2p_event, left}
```

`subscribe/0` is the right entry point if your application needs
to react to cluster changes (cache invalidation, lease renewal,
metric updates).

## Related

- [Gossip broadcast](gossip-broadcast.md) is the protocol that
  uses the active view for message dissemination.
- [Dist channel](dist-channel.md) describes how on-demand
  channels open when sending to a peer outside the active view.
- [Run in production](../how-to/run-in-production.md) has the
  operational sizing table.
- [Architecture](../reference/architecture.md) has the
  supervision-tree-level picture.
