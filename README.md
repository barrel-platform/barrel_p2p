# Mycelium

Mycelium is an Erlang/OTP library for building peer-to-peer distributed applications. It implements the HyParView protocol for scalable cluster membership, combined with a CRDT-based service registry and Plumtree epidemic broadcast for reliable message dissemination.

Unlike traditional Erlang distribution that requires full mesh connectivity, Mycelium maintains only a small number of active connections per node (typically log(n)), making it suitable for large clusters while preserving self-healing properties.

## Project Status

**Experimental, pre-1.0.** APIs may change between minor releases until a `1.0` tag. The cryptographic and transport layers (Ed25519 dist auth, QUIC carrier, circuit framing) have unit and multi-node test coverage but have **not been independently audited**. Don't ship it where a transport-level compromise would be costly without doing your own review first. Bug reports and PRs welcome; see [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## Key Features

- **HyParView Protocol** - Scalable partial membership with O(log n) connections per node
- **Service Registry** - Distributed service discovery using OR-Map CRDTs
- **Plumtree Broadcast** - Efficient epidemic broadcast with O(n) message complexity
- **Hybrid Logical Clocks** - Causally consistent timestamps for conflict resolution
- **Ed25519 Authentication** - Secure peer authentication with TOFU or strict modes
- **QUIC Distribution** - `-proto_dist mycelium` plugs straight into Erlang/OTP's alt-dist. One QUIC connection per peer carries the dist channel, with Ed25519 identity check between handshakes, no stock EPMD daemon, lazy self-signed TLS, and a composing discovery chain (static config + on-disk file registry + DNS).
- **One-shot RPC tooling** - `priv/bin/mycelium_call.sh` — `erl_call`-style helper that boots a hidden probe with full Ed25519 identity and runs `rpc:call/5` against a live mycelium node. Available to any project that depends on mycelium.
- **TLS cert helper** - `priv/bin/mycelium_gen_cert.sh` — one-shot self-signed cert generator (RSA 2048 by default) for the QUIC dist channel; idempotent.
- **Pluggable connect-time overrides** - Inject an external relay/tunnel adapter per peer via `quic_dist:set_connect_options/2` (see [docs/external-relay.md](docs/external-relay.md))
- **Multi-hop circuits** - Stream-shaped channels between cluster nodes that aren't in each other's active view, spliced at intermediate hops on top of the existing dist connections (see [docs/circuits.md](docs/circuits.md))
- **Connection migration** - One-shot RFC 9000 §9 path migration via `mycelium:migrate_peer/1,2`; rebinds the QUIC dist channel to a new local 4-tuple without rekey or HyParView churn (see [docs/migration.md](docs/migration.md))

## Quick Start

```erlang
%% Start the mycelium application
application:ensure_all_started(mycelium).

%% Join an existing cluster
mycelium:join('seed@192.168.1.10').

%% Register a service
mycelium:register_service(my_service, #{version => "1.0"}).

%% Find a service anywhere in the cluster
{ok, Pid} = mycelium:whereis_service(my_service).

%% Subscribe to membership events
mycelium:subscribe().
%% Receives: {hyparview_event, {joined, Node}}
%% Receives: {hyparview_event, {left, Node}}

%% View connected peers
mycelium:active_view().
```

## Installation

Add mycelium to your `rebar.config` dependencies:

```erlang
{deps, [
    {mycelium, "0.1.0"}
]}.
```

Then fetch dependencies:

```bash
rebar3 get-deps
```

## Basic Usage

### Cluster Membership

```erlang
%% Join via a contact node
ok = mycelium:join('contact@host.example.com').

%% Get currently connected peers
Peers = mycelium:active_view().

%% Get known but unconnected peers
Known = mycelium:passive_view().

%% Gracefully leave the cluster
mycelium:leave().
```

### Service Discovery

```erlang
%% Register a service with metadata
mycelium:register_service(user_cache, #{shard => 1}).

%% Find all instances of a service
{ok, Entries} = mycelium:lookup(user_cache).

%% Find any instance (local preferred, then remote)
{ok, Pid} = mycelium:whereis_service(user_cache).

%% Subscribe to service events
mycelium:subscribe_services().
%% Receives: {mycelium_service_event, {service_registered, Name, Node}}
%% Receives: {mycelium_service_event, {service_unregistered, Name, Node}}
```

### Configuration

Configure in your `sys.config`:

```erlang
{mycelium, [
    %% HyParView parameters
    {active_size, 5},        %% Max active connections (log n)
    {passive_size, 30},      %% Max passive view size (c * log n)
    {shuffle_period, 10000}, %% Topology refresh interval (ms)

    %% Distribution (quic_dist carrier)
    {listen_port, 9100},     %% 0 for auto-assign
    {contact_nodes, ['seed@192.168.1.10']},

    %% Authentication
    {auth_enabled, true},
    {auth_trust_mode, tofu}  %% tofu | strict
]}
```

### Distribution carrier

Add to your `vm.args`:

```
-proto_dist mycelium
-epmd_module mycelium_epmd
-start_epmd false
```

That's the entire dist setup. `mycelium_dist` runs on top of
upstream `quic_dist`; it auto-generates the TLS material under
`data/quic/node.{crt,key}` on first listen and wires the Ed25519
auth callback + composing discovery module into the underlying
`quic` app env. Override any default by setting it explicitly under
`{quic, [{dist, [...]}]}` in `sys.config`.

No stock `epmd` daemon is required. All inter-node traffic flows
over a single QUIC connection per peer. Mycelium does not bundle
NAT traversal or relay; nodes are expected to reach each other
directly. When a tunnel/relay is needed, register an external
socket adapter with `quic_dist:set_connect_options/2` (see
[docs/external-relay.md](docs/external-relay.md)).

## Testing

`rebar3 ct` runs the local CT suites; the docker scripts under
`docker/scripts/` exercise the multi-node clusters. See
[docs/testing.md](docs/testing.md) for the full command list.

## Example

A small distributed chat app lives under [`examples/chat`](examples/chat/README.md). To run a two-node demo:

```bash
cd examples/chat
./scripts/run-demo.sh seed                    # terminal 1
./scripts/run-demo.sh node 1                  # terminal 2
```

The script links the local mycelium tree as a `_checkouts` override and starts each node with `-proto_dist mycelium`; the TLS cert under `data/quic/` is generated on first listen. See `examples/chat/README.md` for the three-node walkthrough and the docker compose stack.

## Documentation

- [Getting Started](docs/getting-started.md) - Installation, first-boot setup (TLS cert, Ed25519 keypair), and first cluster
- [Building P2P Applications](docs/tutorial.md) - Tutorial with worked examples
- [Authentication](docs/authentication.md) - Ed25519 key management and trust modes
- [Circuits](docs/circuits.md) - Multi-hop streams over the dist QUIC channel
- [Connection migration](docs/migration.md) - RFC 9000 §9 path migration via `migrate_peer/1,2`
- [External Relay](docs/external-relay.md) - Wiring an out-of-tree tunnel/relay adapter
- [Comparison with Partisan](docs/partisan-comparison.md) - When to use which
- [Testing](docs/testing.md) - Running local and docker test suites
- [Internals](docs/internals.md) - Architecture and protocol details

## API Reference

Generate HTML documentation:

```bash
rebar3 ex_doc
```

## License

Apache-2.0
