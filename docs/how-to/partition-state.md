# Partition state across nodes

You have per-key state (a cache, a counter, an in-memory aggregate)
that is too big or too hot for one node, and you want each key handled
by exactly one node, with automatic hand-off when the cluster changes.
This is what `barrel_p2p_shard` gives you.

## Route a key to its owner

Anywhere in the cluster, ask who owns a key and act accordingly:

```erlang
handle(Key, Request) ->
    case barrel_p2p:place(Key) of
        Node when Node =:= node() ->
            handle_locally(Key, Request);
        Other ->
            %% Forward to the owner. Any transport works; a registered
            %% gen_server reached through the dist channel is simplest.
            gen_server:call({my_shard_server, Other}, {Key, Request})
    end.
```

Every node computes the same owner for `Key`, so a client can hit any
node and the request lands on the one node that holds the state.

## Hold state for the partitions you own

A shard worker owns a slice of the ring. Subscribe to ownership events,
load state when you acquire a partition, and drop it when you lose one:

```erlang
-behaviour(gen_server).

init(_) ->
    ok = barrel_p2p:subscribe_shard(),
    %% Take over whatever we already own at boot.
    Owned = [P || P <- lists:seq(0, ring_size() - 1), owns(P)],
    {ok, #{owned => sets:from_list(Owned), state => #{}}}.

handle_info({barrel_p2p_shard, {acquired, P}}, S) ->
    {noreply, load_partition(P, S)};
handle_info({barrel_p2p_shard, {released, P}}, S) ->
    {noreply, drop_partition(P, S)}.

owns(P) ->
    %% A partition is ours when its owner is this node.
    barrel_p2p:place({partition_probe, P}) =:= node().

ring_size() ->
    application:get_env(barrel_p2p, ring_size, 64).
```

To find which keys an event covers, map your keys to partitions with
`barrel_p2p:partition(Key)`. Keep a key only if `barrel_p2p:is_owner(Key)`.

## Replicate a key across N nodes

For state you cannot afford to lose on a single node death, place a key
on its top-N owners and write to all of them:

```erlang
put(Key, Value) ->
    [ gen_server:cast({my_shard_server, N}, {put, Key, Value})
      || N <- barrel_p2p:owners(Key, 3) ],
    ok.

get(Key) ->
    %% Read from the first reachable owner, best owner first.
    first_reachable(barrel_p2p:owners(Key, 3), Key).
```

When a node dies, HRW moves only that node's partitions, so the other
two replicas are unaffected and a fresh third owner is chosen for the
moved keys.

## Make hand-off safe

Ownership is eventually consistent. During churn a partition can be
owned on two nodes for a short window before the member set converges,
so:

- Make `acquired` (load / take over) and `released` (drop / hand off)
  **idempotent**: acquiring a partition you already serve, or dropping
  one you already dropped, must be harmless.
- Do not treat losing a partition as data loss. The new owner loads the
  same keys; if the data is authoritative elsewhere (a database, the
  replicas above), hand-off is just moving the cache.

## Tune the lease, cluster-wide

`ring_size`, `member_heartbeat_ms`, `member_ttl_ms`, and
`member_skew_ms` must be the same on every node, or nodes compute
different rings. Set them in `sys.config`:

```erlang
{barrel_p2p, [
    {ring_size, 128},
    {member_heartbeat_ms, 2000},
    {member_ttl_ms, 6000}
]}.
```

A larger `ring_size` spreads keys more evenly and makes ownership
events finer-grained, at the cost of more per-partition bookkeeping.
Keep `member_ttl_ms` well above `member_heartbeat_ms` plus the clock
skew you expect, so a live node is never swept between beats.

## See also

- [Sharded placement](../concepts/sharded-placement.md) for the model
  and the consistency guarantees.
