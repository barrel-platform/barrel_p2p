# API overview

Every public function in `barrel_p2p.erl`, grouped by subsystem.
Each entry shows the spec and the stability tier in
[features.md](../features.md).

For implementation modules (`barrel_p2p_dist_keys`,
`barrel_p2p_dist_auth`, `barrel_p2p_streams`, etc.), see the
generated [API reference](../api-reference.html) sidebar or the
per-concept pages.

## Cluster membership

```erlang
%% Join a cluster through a contact node.
%% supported.
-spec join(ContactNode :: node()) -> ok | {error, term()}.

%% Leave the cluster gracefully.
%% supported.
-spec leave() -> ok.

%% Return the current HyParView active view.
%% supported.
-spec active_view() -> [node()].

%% Return the passive view (known but disconnected peers).
%% supported.
-spec passive_view() -> [node()].
```

## Membership events

```erlang
%% Subscribe the calling pid (or a specific pid) to events.
%% Idempotent: subscribing twice is a no-op.
%% supported.
-spec subscribe() -> ok.
-spec subscribe(Pid :: pid()) -> ok.
-spec unsubscribe(Pid :: pid()) -> ok.
```

Events delivered as messages:

```erlang
{barrel_p2p_event, {peer_up, Node}}.
{barrel_p2p_event, {peer_down, Node, Reason}}.
{barrel_p2p_event, joined}.
{barrel_p2p_event, left}.
```

## Service registry

```erlang
%% Register the current process as a named service.
%% supported.
-spec register_service(Name :: atom() | binary()) -> ok | {error, term()}.
-spec register_service(Name, Meta :: map()) -> ok | {error, term()}.
-spec register_service(Name, Pid :: pid(), Meta :: map()) -> ok | {error, term()}.

%% Remove a registration.
%% supported.
-spec unregister_service(Name) -> ok.

%% Local registry only.
%% supported.
-spec lookup_local(Name) -> {ok, pid()} | {error, not_found}.

%% Every replica we know of.
%% supported.
-spec lookup(Name) -> {ok, [#service_entry{}]} | {error, not_found}.

%% Full names list.
%% supported.
-spec list_services() -> [Name].

%% Single best match: local preferred, then remote, then overlay.
%% supported.
-spec whereis_service(Name) ->
    {ok, pid()} | {ok, node(), pid()} | {error, not_found}.
-spec whereis_service(Name, Opts :: #{retries => non_neg_integer()}) ->
    {ok, pid()} | {ok, node(), pid()} | {error, not_found}.
```

## Service events

```erlang
%% Subscribe to service registry events.
%% beta. Event shape may evolve across 0.x minors.
-spec subscribe_services() -> ok.
-spec subscribe_services(Pid) -> ok.
-spec unsubscribe_services(Pid) -> ok.
```

Events delivered as messages:

```erlang
{barrel_p2p_service_event, {service_registered, Name, Node}}.
{barrel_p2p_service_event, {service_unregistered, Name, Node}}.
{barrel_p2p_service_event, {service_down, Name, Node, Reason}}.
```

## Via callbacks (`{via, barrel_p2p, Name}`)

The standard name-registration interface. Use barrel_p2p as a
process registry with `gen_server`, `gen_statem`, etc.

```erlang
%% supported.
-spec register_name(Name :: term(), Pid :: pid()) -> yes | no.
-spec unregister_name(Name :: term()) -> ok.
-spec whereis_name(Name :: term()) -> pid() | undefined.
-spec send(Name :: term(), Msg :: term()) -> pid().
```

Example:

```erlang
%% Start a gen_server registered through barrel_p2p.
gen_server:start({via, barrel_p2p, my_service}, my_module, [], []).

%% Call it by name.
gen_server:call({via, barrel_p2p, my_service}, request).

%% Send to it.
barrel_p2p:send(my_service, Msg).
```

## Connection migration

```erlang
%% Trigger RFC 9000 §9 path migration on the QUIC connection
%% backing the dist channel to Node.
%% beta. Opts may grow new keys; existing keys stay.
-spec migrate_peer(Node :: node()) -> ok | {error, term()}.
-spec migrate_peer(Node, Opts :: #{timeout => pos_integer()}) ->
    ok | {error, term()}.
```

Errors documented under
[connection migration](../concepts/connection-migration.md).

## Leader election (`beta`)

```erlang
%% Campaign for the singleton Name. Returns the initial role;
%% transitions arrive as {barrel_p2p_leader, Name, {elected, Fence} | revoked}.
-spec lead(Name) -> {ok, {leader, non_neg_integer()}} | {ok, follower}
                  | {error, term()}.
-spec lead(Name, Opts :: #{priority => integer()}) -> same.
-spec resign(Name) -> ok.
-spec leader(Name) -> {ok, node(), pid()} | {error, no_leader}.
-spec is_leader(Name) -> boolean().
-spec fence(Name) -> {ok, non_neg_integer()} | {error, not_leader}.
```

See [leader election](../concepts/leader-election.md).

## Sharded placement (`beta`)

```erlang
%% Owner of Key cluster-wide (eventual agreement). undefined only
%% before the local member set is seeded.
-spec place(Key) -> node() | undefined.
%% Top-N distinct owners (best first), for replicated placement.
-spec owners(Key, N :: pos_integer()) -> [node()].
-spec is_owner(Key) -> boolean().
%% Ring partition Key falls in (0..ring_size-1).
-spec partition(Key) -> non_neg_integer().
%% Current live member set (sorted).
-spec members() -> [node()].
%% Subscribe to {barrel_p2p_shard, {acquired | released, Partition}}.
-spec subscribe_shard() -> ok.
-spec subscribe_shard(Pid :: pid()) -> ok.
```

See [sharded placement](../concepts/sharded-placement.md) and
[partition state across nodes](../how-to/partition-state.md).

## Durable reminders (`beta`)

```erlang
%% Fire at an absolute wall-clock instant (system_time(millisecond)
%% scale); Payload is delivered on the owning node. Re-setting a Key
%% replaces it. Exactly once in steady state, best-effort under churn.
-spec remind(Key, FireAtMs :: integer(), Payload) -> ok.
%% Fire DelayMs from now (converted to an absolute target).
-spec remind_after(Key, DelayMs :: non_neg_integer(), Payload) -> ok.
%% Cancel cluster-wide.
-spec cancel_reminder(Key) -> ok.
%% Subscribe to {barrel_p2p_reminder, Key, Payload, Fence}.
-spec subscribe_reminders() -> ok.
-spec subscribe_reminders(Pid :: pid()) -> ok.
-spec unsubscribe_reminders(Pid :: pid()) -> ok.
```

Delivered to subscribers on the firing (owner) node:

```erlang
%% Fence :: non_neg_integer() is the packed version stamp; stable
%% across nodes, usable to dedup an idempotent handler.
{barrel_p2p_reminder, Key, Payload, Fence}.
```

See [durable reminders](../concepts/durable-reminders.md) and
[schedule durable jobs](../how-to/schedule-durable-jobs.md).

## Replicated maps (`beta`)

```erlang
%% Start a named map on THIS node (idempotent). A map is node-local:
%% host it on every participating node (the replicated_maps env, or
%% new_map/2 per node). Opts: validator | tombstone_ttl_ms | scan_ms |
%% prune_on_peer_down.
-spec new_map(Name :: atom()) -> {ok, pid()} | {error, term()}.
-spec new_map(Name, Opts :: barrel_p2p_map:opts()) -> {ok, pid()} | {error, term()}.
%% Stop the map on THIS node (node-local; not a cluster-wide erase).
-spec delete_map(Name) -> ok.
%% {error, invalid_value} if the map's validator rejects Value.
-spec map_put(Name, Key, Value) -> ok | {error, invalid_value | no_such_map}.
-spec map_remove(Name, Key) -> ok | {error, no_such_map}.
%% Lock-free ETS reads.
-spec map_get(Name, Key) -> {ok, term()} | not_found.
-spec map_keys(Name) -> [term()].
-spec map_to_list(Name) -> [{term(), term()}].
%% Subscribe to {barrel_p2p_map, Name, {put, K, V} | {remove, K}}.
-spec subscribe_map(Name) -> ok | {error, no_such_map}.
-spec subscribe_map(Name, Pid :: pid()) -> ok | {error, no_such_map}.
-spec unsubscribe_map(Name) -> ok | {error, no_such_map}.
-spec unsubscribe_map(Name, Pid :: pid()) -> ok | {error, no_such_map}.
```

See [replicated maps](../concepts/replicated-maps.md),
[share replicated state](../how-to/share-replicated-state.md), and
[the replicated substrate](replicated-substrate.md) for custom merge.

## Global integration (`beta`)

```erlang
%% Register a service with global for transparency.
%% beta.
-spec global_register(Name) -> {ok, pid()} | {error, term()}.

%% Get the existing proxy pid for a service, if any.
%% beta.
-spec get_proxy(Name) -> {ok, pid()} | not_found.
```

## Test helpers (`experimental`)

These will likely move to a dedicated test-helper module before
1.0.

```erlang
%% Spawn a long-lived holder that registers a service and
%% receives stop.
%% experimental.
-spec start_service_holder(Name) -> {ok, pid()} | {error, term()}.
-spec stop_service_holder(Pid) -> ok.
```

## Related modules

For finer-grained control, the following modules are also
public. Each one's concept page or how-to has the full surface;
the entries here are the most commonly used.

### `barrel_p2p_dist_keys`

```erlang
barrel_p2p_dist_keys:store_key(Node, PubKey).
barrel_p2p_dist_keys:lookup_pin(Node).
barrel_p2p_dist_keys:delete_key(Node).
barrel_p2p_dist_keys:list_trusted().
barrel_p2p_dist_keys:set_trust_mode(tofu | strict).
barrel_p2p_dist_keys:get_trust_mode().
barrel_p2p_dist_keys:fingerprint(PubKey).
```

See [configure authentication](../how-to/configure-authentication.md).

### `barrel_p2p_dist_auth`

```erlang
barrel_p2p_dist_auth:ensure_keypair().
barrel_p2p_dist_auth:get_public_key().
barrel_p2p_dist_auth:is_cookie_only_allowed(Node).
```

### `barrel_p2p_rotate`

```erlang
barrel_p2p_rotate:rotate_identity().
barrel_p2p_rotate:rotate_cert().
```

See [configure authentication](../how-to/configure-authentication.md).

### `barrel_p2p_streams`

```erlang
barrel_p2p_streams:register_acceptor(Tag, Pid).
barrel_p2p_streams:unregister_acceptor(Tag).
barrel_p2p_streams:open(Tag, Node).
barrel_p2p_streams:list_acceptors().
```

See the [streams concept](../concepts/streams.md).

### `barrel_p2p_path_stats`

```erlang
barrel_p2p_path_stats:srtt(Node).
barrel_p2p_path_stats:summary(Node).
barrel_p2p_path_stats:connection(Node).
```

Read-only views over the underlying QUIC path stats. Useful for
diagnostics and migration triggers; see
[migrate connections](../how-to/migrate-connections.md).

### `barrel_p2p_hlc`

```erlang
barrel_p2p_hlc:now().
barrel_p2p_hlc:update(PeerTs).
barrel_p2p_hlc:compare(T1, T2).
barrel_p2p_hlc:wall_time(Ts).
barrel_p2p_hlc:logical(Ts).
barrel_p2p_hlc:to_binary(Ts).
barrel_p2p_hlc:from_binary(Bin).
```

See the [hybrid logical clocks concept](../concepts/hybrid-logical-clocks.md).

## Stability tiers

The tiers `supported`, `beta`, `experimental` follow the
contract in [features.md](../features.md):

- **supported** survives across minor bumps with deprecation
  notices in the CHANGELOG.
- **beta** is likely stable; expect shape changes across
  minors.
- **experimental** can change without warning.

Anything not listed there is internal.

## Related

- [Configuration](configuration.md) for `sys.config` keys.
- [Architecture](architecture.md) for the supervision tree and
  protocol-level details.
- [Concepts](../concepts/index.md) for the per-subsystem
  explanations.
