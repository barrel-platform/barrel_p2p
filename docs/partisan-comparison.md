# Mycelium vs Partisan Comparison

Both Mycelium and Partisan address the scalability limitations of Erlang's built-in distribution. This guide helps you understand their differences and choose the right library for your needs.

## Overview

### Partisan

Partisan is a flexible, TCP-based distributed systems framework that replaces Erlang distribution. It provides multiple overlay topologies and a channel-based communication model, designed for research and production distributed systems.

**Key characteristics:**
- Multiple topology backends (full mesh, HyParView, client-server, etc.)
- Channel-based message routing with parallelism
- Pluggable storage and broadcast modules
- Focus on research flexibility

### Mycelium

Mycelium is an Erlang distribution enhancement focused on HyParView membership with integrated service discovery. It augments rather than replaces Erlang distribution.

**Key characteristics:**
- HyParView-only topology with opinionated defaults
- Built-in CRDT service registry
- Transparent overlay routing for service discovery
- Focus on operational simplicity

## Architecture Comparison

| Aspect | Partisan | Mycelium |
|--------|----------|----------|
| Erlang Distribution | Replaces | Enhances |
| Topology | Configurable (full mesh, HyParView, etc.) | HyParView only |
| Service Discovery | External (via Plumtree) | Built-in CRDT registry |
| Message Routing | Channels with explicit parallelism | Transparent overlay routing |
| Configuration | Highly configurable | Convention over configuration |
| State Sync | Pluggable broadcast | Plumtree with OR-Map CRDT |

### Distribution Model

**Partisan** replaces Erlang distribution entirely:
```erlang
%% Messages use partisan_peer_service
partisan_peer_service:forward_message(Node, Message).

%% Or via channels
partisan_peer_service:forward_message(Node, Channel, Message).
```

**Mycelium** enhances Erlang distribution:
```erlang
%% Standard Erlang messaging still works
Pid ! Message.

%% Service discovery adds overlay routing
{ok, Pid} = mycelium:whereis_service(my_service),
gen_server:call(Pid, request).
```

### Topology Management

**Partisan** offers multiple backends:
```erlang
%% Configure topology in sys.config
{partisan, [
    {peer_service_manager, partisan_hyparview_peer_service_manager}
    %% Or: partisan_full_mesh_peer_service_manager
    %% Or: partisan_client_server_peer_service_manager
]}
```

**Mycelium** uses HyParView exclusively:
```erlang
{mycelium, [
    {active_size, 5},   %% Tune the parameters
    {passive_size, 30}
]}
```

## Feature Comparison

| Feature | Partisan | Mycelium |
|---------|----------|----------|
| Full mesh topology | Yes | No |
| HyParView topology | Yes | Yes (only) |
| Client-server topology | Yes | No |
| Service registry | No (use external) | Yes (built-in) |
| Channels | Yes (named, parallel) | No |
| Broadcast | Plumtree (configurable) | Plumtree (integrated) |
| Authentication | Optional | Ed25519 built-in |
| State replication | Pluggable | OR-Map CRDT |
| Erlang global | Not compatible | Compatible |
| Process monitoring | Custom | Standard Erlang |

### Service Discovery

**Partisan** requires external service discovery:
```erlang
%% Use Plumtree or external solution
partisan_plumtree_backend:broadcast(update, ServiceState).

%% Or integrate with external registry
```

**Mycelium** has built-in service discovery:
```erlang
%% Register
mycelium:register_service(my_service, #{version => "1.0"}).

%% Discover (anywhere in cluster)
{ok, Pid} = mycelium:whereis_service(my_service).

%% Subscribe to changes
mycelium:subscribe_services().
```

### Message Channels

**Partisan** provides explicit parallelism via channels:
```erlang
%% Send on specific channel for ordering guarantees
partisan_peer_service:forward_message(Node, {channel, high_priority}, Msg).

%% Configure channel parallelism
{partisan, [
    {channels, [
        {high_priority, #{parallelism => 1}},
        {bulk_data, #{parallelism => 4}}
    ]}
]}
```

**Mycelium** uses standard Erlang messaging:
```erlang
%% Direct messaging through overlay
Pid ! Message.

%% Or via gen_server
gen_server:call(Pid, request).
```

## When to Use Mycelium

Choose Mycelium when you need:

1. **Simple service discovery** - Built-in registry without external dependencies
2. **Standard Erlang patterns** - gen_server, monitors, links work normally
3. **Minimal configuration** - Sensible defaults, fewer decisions
4. **Quick integration** - Add to existing Erlang applications easily
5. **Ed25519 authentication** - Secure peer verification out of the box

**Good fit for:**
- Microservice architectures needing service discovery
- Applications migrating from full mesh to partial membership
- Teams wanting opinionated defaults over flexibility
- Projects requiring secure peer authentication

## When to Use Partisan

Choose Partisan when you need:

1. **Topology flexibility** - Full mesh, client-server, or custom topologies
2. **Channel-based routing** - Explicit parallelism and message ordering
3. **Research platforms** - Experimenting with distributed protocols
4. **Custom broadcast** - Pluggable broadcast backends
5. **Non-HyParView topologies** - Some use cases need full mesh or star

**Good fit for:**
- Distributed systems research
- Applications requiring multiple topology modes
- Systems needing fine-grained channel control
- Projects requiring full mesh for small clusters

## Migration Considerations

### From Partisan to Mycelium

1. **Replace membership calls**
   ```erlang
   %% Partisan
   partisan_peer_service:join(Node).
   partisan_peer_service:members().

   %% Mycelium
   mycelium:join(Node).
   mycelium:active_view().
   ```

2. **Replace message forwarding with service discovery**
   ```erlang
   %% Partisan
   partisan_peer_service:forward_message(Node, Msg).

   %% Mycelium - use services
   {ok, Pid} = mycelium:whereis_service(target_service),
   Pid ! Msg.
   ```

3. **Channels become standard messaging** - Remove channel routing, use standard Erlang

### From Mycelium to Partisan

1. **Add channel configuration** - Define channels for different message types
2. **Replace service registry** - Implement via Plumtree or external registry
3. **Update message patterns** - Use `partisan_peer_service:forward_message/3`

## Performance Considerations

| Aspect | Partisan | Mycelium |
|--------|----------|----------|
| Connection overhead | Depends on topology | O(log n) always |
| Message latency | Channel-dependent | Standard Erlang |
| Service lookup | External | Local cache + overlay |
| State sync | Configurable | Automatic CRDT merge |

Both libraries scale to large clusters. Choose based on your specific requirements rather than performance alone.

## Summary

| If you need... | Use |
|---------------|-----|
| Built-in service discovery | Mycelium |
| Multiple topology options | Partisan |
| Standard Erlang messaging | Mycelium |
| Channel-based parallelism | Partisan |
| Minimal configuration | Mycelium |
| Maximum flexibility | Partisan |
| Research platform | Partisan |
| Production service mesh | Either |
