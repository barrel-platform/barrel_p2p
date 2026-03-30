# Mycelium

Mycelium is an Erlang/OTP library for building peer-to-peer distributed applications. It implements the HyParView protocol for scalable cluster membership, combined with a CRDT-based service registry and Plumtree epidemic broadcast for reliable message dissemination.

Unlike traditional Erlang distribution that requires full mesh connectivity, Mycelium maintains only a small number of active connections per node (typically log(n)), making it suitable for large clusters while preserving self-healing properties.

## Key Features

- **HyParView Protocol** - Scalable partial membership with O(log n) connections per node
- **Service Registry** - Distributed service discovery using OR-Map CRDTs
- **Plumtree Broadcast** - Efficient epidemic broadcast with O(n) message complexity
- **Circuit Routing** - Multi-hop encrypted channels with end-to-end privacy
- **Hybrid Logical Clocks** - Causally consistent timestamps for conflict resolution
- **Ed25519 Authentication** - Secure peer authentication with TOFU or strict modes
- **Pluggable Transport** - TCP and TLS distribution carriers

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

%% Create a secure circuit to another node
{ok, CircuitId} = mycelium:circuit_create('target@host').
mycelium:circuit_send(CircuitId, <<"encrypted data">>).
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

    %% Distribution
    {listen_port, 9100},     %% 0 for auto-assign
    {contact_nodes, ['seed@192.168.1.10']},

    %% Authentication
    {auth_enabled, true},
    {auth_trust_mode, tofu}  %% tofu | strict
]}
```

## Documentation

- [Getting Started](docs/getting-started.md) - Installation and first steps
- [Building P2P Applications](docs/tutorial.md) - Tutorial with worked examples
- [Circuit Routing](docs/circuits.md) - Multi-hop encrypted communication
- [Authentication](docs/authentication.md) - Ed25519 key management and trust modes
- [Comparison with Partisan](docs/partisan-comparison.md) - When to use which
- [Internals](docs/internals.md) - Architecture and protocol details

## API Reference

Generate HTML documentation:

```bash
rebar3 ex_doc
```

## License

Apache-2.0
