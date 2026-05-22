# Leader election and singletons

Many applications need "exactly one node runs this job": a cron
driver, a queue compactor, a shard owner. Mycelium provides this as
a small campaign-and-notify API. A process calls `mycelium:lead/2`,
the cluster elects one leader, and the leader is re-elected
automatically when membership changes.

Because mycelium is an AP/gossip system with no consensus layer,
election is deterministic rather than coordinated, and each
leadership term carries a fencing token so a stale leader cannot
corrupt shared state. This page explains both.

## The campaign-and-notify model

The calling process is the candidate. It is monitored, so if it dies
it stops being a candidate. `lead/2` returns the caller's initial
role, and every later transition arrives as a message:

```erlang
%% The worker process campaigns, then runs only while it leads.
run() ->
    case mycelium:lead(report_roller) of
        {ok, {leader, Fence}}  -> start_job(Fence);
        {ok, follower}         -> wait()
    end,
    loop().

loop() ->
    receive
        {mycelium_leader, report_roller, {elected, Fence}} ->
            start_job(Fence), loop();
        {mycelium_leader, report_roller, revoked} ->
            stop_job(), loop()
    end.
```

Supporting calls:

```erlang
mycelium:leader(report_roller).     %% {ok, Node, Pid} | {error, no_leader}
mycelium:is_leader(report_roller).  %% boolean()
mycelium:fence(report_roller).      %% {ok, Fence} | {error, not_leader}
mycelium:resign(report_roller).     %% step down (no `revoked' is sent)
```

The caller owns its own job lifecycle: mycelium tells it when it
holds leadership and when it loses it, and the caller decides what to
start and stop.

## How the winner is chosen

Every node holds a replicated set of candidates (which node is
campaigning for which name), gossiped exactly like the
[service registry](service-registry.md): an OR-Map keyed by
`{Name, node()}`, broadcast over [Plumtree](gossip-broadcast.md),
full-synced on `peer_up`, and pruned on `peer_down`.

Given that set, each node computes the leader independently and
identically:

1. highest `priority` (a `lead/2` option, default `0`),
2. ties broken by the lowest node atom.

No votes, no quorum, no coordination round. Two nodes with the same
candidate set always agree. During membership flux they may disagree
briefly and then converge, which is the same trade the bare
`whereis_service` + node-atom approach already makes.

`priority` lets you pin a preference (for example a node with more
resources) without giving up the deterministic tiebreaker:

```erlang
mycelium:lead(shard_owner, #{priority => 1}).  %% beats priority 0
```

## Re-election

Re-election is driven by the same membership events the rest of
mycelium uses:

- A new candidate appears (someone calls `lead/2`): its candidacy
  gossips out, every node recomputes, and a node that loses gets
  `revoked`.
- The leader resigns or its process dies: the candidacy is
  tombstoned and the next-best candidate is elected.
- The leader's node leaves or fails (`peer_down`): each surviving
  node drops that node's candidacies and recomputes. The next-best
  survivor is elected.

## Fencing

A leader that is paused (long GC), partitioned, or simply slow can
keep believing it leads after the cluster has moved on. If it then
writes to a shared resource, it corrupts state. This is the classic
split-brain hazard, and election alone does not solve it.

The fix is a **fencing token**. Each leadership term mints one, and
the leader stamps it on every write to the protected resource. The
resource records the highest token it has accepted and rejects any
operation whose token is not strictly greater:

```erlang
{ok, {leader, Fence}} = mycelium:lead(ledger_writer),
ok = ledger:append(Entry, #{fence => Fence}).

%% Inside the resource:
append(Entry, #{fence := F}) when F > LastAcceptedFence ->
    do_append(Entry, F);
append(_Entry, _) ->
    {error, fenced_out}.   %% a newer leader has taken over
```

A revoked leader's token is now stale, so its late writes are
refused. That is what turns "we elected one leader" into "exactly
one leader can actually mutate state".

### How the token is built

The token is a `non_neg_integer()`, minted from mycelium's
[hybrid logical clock](hybrid-logical-clocks.md). When a node takes a
term it advances its HLC past a replicated per-name high-water mark
and then takes a fresh timestamp, so the new token is strictly
greater than every token observed in its connected component. The
high-water mark is gossiped, so the next leader (on any node) mints
above it.

### What the guarantee is, and is not

- **Within a connected partition**, tokens are strictly monotonic:
  each term's token exceeds every earlier term's. This is the
  property the resource check relies on, and it holds across a real
  leader death (proven in `mycelium_leader_e2e_SUITE`: kill the
  leader, the survivor takes over with a strictly greater token).
- **Across a network partition**, mycelium cannot guarantee
  monotonicity without a consensus layer it deliberately does not
  have. Each side may elect its own leader. Safety then rests
  entirely on the resource's reject-if-not-greater check; the HLC
  wall-clock component keeps cross-partition tokens approximately
  ordered, but you must not assume strict ordering there.

If you need cross-partition exclusivity guarantees, you need a
consensus system; that is outside mycelium's AP design.

## API

```erlang
%% Campaign. Returns the initial role; transitions arrive as messages.
lead(Name) -> {ok, {leader, Fence}} | {ok, follower} | {error, term()}.
lead(Name, #{priority => integer()}) -> same.

%% Messages delivered to the candidate process:
%%   {mycelium_leader, Name, {elected, Fence}}
%%   {mycelium_leader, Name, revoked}

resign(Name)    -> ok.
leader(Name)    -> {ok, node(), pid()} | {error, no_leader}.
is_leader(Name) -> boolean().
fence(Name)     -> {ok, Fence} | {error, not_leader}.

%% Name :: term().  Fence :: non_neg_integer().
```

The API is **beta**: the message and return shapes may change across
a 0.x minor bump.

## Related

- [Service registry](service-registry.md) shares the OR-Map and
  gossip machinery that replicates the candidate set.
- [Gossip broadcast](gossip-broadcast.md) is how candidacies and
  fencing high-water marks propagate.
- [Hybrid logical clocks](hybrid-logical-clocks.md) are the source of
  the fencing token.
- [Cluster membership](cluster-membership.md) provides the
  `peer_up` / `peer_down` events that drive re-election.
