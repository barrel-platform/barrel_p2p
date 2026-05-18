# API overview

Every public function in `mycelium.erl`, grouped by subsystem.
Each entry shows the spec and the stability tier in
[features.md](../../doc/features.md).

For implementation modules (`mycelium_dist_keys`,
`mycelium_dist_auth`, `mycelium_streams`, etc.), see the
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
{mycelium_event, {peer_up, Node}}.
{mycelium_event, {peer_down, Node, Reason}}.
{mycelium_event, joined}.
{mycelium_event, left}.
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
{mycelium_service_event, {service_registered, Name, Node}}.
{mycelium_service_event, {service_unregistered, Name, Node}}.
{mycelium_service_event, {service_down, Name, Node, Reason}}.
```

## Via callbacks (`{via, mycelium, Name}`)

The standard name-registration interface. Use mycelium as a
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
%% Start a gen_server registered through mycelium.
gen_server:start({via, mycelium, my_service}, my_module, [], []).

%% Call it by name.
gen_server:call({via, mycelium, my_service}, request).

%% Send to it.
mycelium:send(my_service, Msg).
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

### `mycelium_dist_keys`

```erlang
mycelium_dist_keys:store_key(Node, PubKey).
mycelium_dist_keys:lookup_pin(Node).
mycelium_dist_keys:delete_key(Node).
mycelium_dist_keys:list_trusted().
mycelium_dist_keys:set_trust_mode(tofu | strict).
mycelium_dist_keys:get_trust_mode().
mycelium_dist_keys:fingerprint(PubKey).
```

See [configure authentication](../how-to/configure-authentication.md).

### `mycelium_dist_auth`

```erlang
mycelium_dist_auth:ensure_keypair().
mycelium_dist_auth:get_public_key().
mycelium_dist_auth:is_cookie_only_allowed(Node).
```

### `mycelium_rotate`

```erlang
mycelium_rotate:rotate_identity().
mycelium_rotate:rotate_cert().
```

See [configure authentication](../how-to/configure-authentication.md).

### `mycelium_streams`

```erlang
mycelium_streams:register_acceptor(Tag, Pid).
mycelium_streams:unregister_acceptor(Tag).
mycelium_streams:open(Tag, Node).
mycelium_streams:list_acceptors().
```

See the [streams concept](../concepts/streams.md).

### `mycelium_path_stats`

```erlang
mycelium_path_stats:srtt(Node).
mycelium_path_stats:summary(Node).
mycelium_path_stats:connection(Node).
```

Read-only views over the underlying QUIC path stats. Useful for
diagnostics and migration triggers; see
[migrate connections](../how-to/migrate-connections.md).

### `mycelium_hlc`

```erlang
mycelium_hlc:now().
mycelium_hlc:update(PeerTs).
mycelium_hlc:compare(T1, T2).
mycelium_hlc:wall_time(Ts).
mycelium_hlc:logical(Ts).
mycelium_hlc:to_binary(Ts).
mycelium_hlc:from_binary(Bin).
```

See the [hybrid logical clocks concept](../concepts/hybrid-logical-clocks.md).

## Stability tiers

The tiers `supported`, `beta`, `experimental` follow the
contract in [features.md](../../doc/features.md):

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
