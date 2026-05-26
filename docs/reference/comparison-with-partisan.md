# Barrel P2P and Partisan

Both barrel_p2p and [Partisan](https://github.com/lasp-lang/partisan)
address the limits of Erlang's built-in distribution: the full-mesh
topology that becomes expensive past a few dozen nodes, and the
lack of secure-by-default authentication between peers. They reach
that target from different directions; this document helps you
choose between them.

The short version: pick barrel_p2p when you want service discovery,
secure dist out of the box, and few configuration choices. Pick
Partisan when you want topology flexibility, explicit message
channels, and a research-grade toolkit.

## What each one is

**Partisan** is a distributed-systems toolkit. It replaces Erlang
distribution entirely with its own peer-service abstraction;
several topology backends are available (full mesh, HyParView,
client-server, custom), and messages flow through named channels
with configurable parallelism. Partisan is designed for research
on distributed protocols and for production systems that need the
flexibility.

**Barrel P2P** is an enhancement to Erlang distribution. It runs as
a proto_dist module, so `Pid ! Msg`, `gen_server:call/2`,
`rpc:call/4`, and `global` keep working. It ships one membership
protocol (HyParView), one broadcast protocol (Plumtree), one
service registry (CRDT-backed), one transport (QUIC), and one
authentication layer (Ed25519). The defaults are opinionated; the
configuration surface is small.

## Side by side

| Dimension                         | Partisan                                                       | Barrel P2P                                                                |
|-----------------------------------|----------------------------------------------------------------|-------------------------------------------------------------------------|
| Relationship to Erlang dist       | Replaces                                                       | Enhances (proto_dist module over QUIC)                                  |
| Topology                          | Configurable (full mesh, HyParView, client-server, custom)     | HyParView only                                                          |
| Messaging surface                 | `partisan_peer_service:forward_message/2,3` + channels         | Standard `Pid ! Msg`, `gen_server:call/2`, etc.                          |
| Service discovery                 | External (or build on Plumtree)                                | Built in (CRDT-backed registry)                                          |
| Authentication                    | Optional                                                       | Ed25519 mutual auth by default                                          |
| State replication                 | Pluggable broadcast modules                                    | Plumtree + OR-Map CRDT (fixed)                                          |
| Transport                         | TCP                                                            | QUIC (encrypted by default; per-pair stream multiplexing; connection migration) |
| `global` compatibility            | No                                                             | Yes                                                                     |
| Process monitors / links          | Custom                                                         | Standard Erlang                                                          |

## How a message gets sent

In Partisan, you reach for the peer-service abstraction:

```erlang
%% Forward a message to a peer (default channel)
partisan_peer_service:forward_message(Node, Message).

%% Forward on a named channel with explicit parallelism
partisan_peer_service:forward_message(Node, {channel, high_priority}, Message).
```

The channel layer is where Partisan's flexibility lives: you can
declare multiple channels with different parallelism degrees, and
the framework will fan messages out across the configured
connections.

In barrel_p2p, you reach for whatever you would have reached for in
plain Erlang:

```erlang
%% Send to a pid
Pid ! Message.

%% Or look up a service by name
{ok, _Node, Pid} = barrel_p2p:whereis_service(my_service),
gen_server:call(Pid, Request).
```

For a local service the return shape is `{ok, Pid}`; for a remote
service it is `{ok, Node, Pid}`. The dist channel is opened on
demand. There are no channels to configure.

## How membership is configured

In Partisan, you pick a topology backend:

```erlang
{partisan, [
    {peer_service_manager, partisan_hyparview_peer_service_manager}
    %% Or: partisan_full_mesh_peer_service_manager
    %% Or: partisan_client_server_peer_service_manager
    %% Or: your own
]}
```

In barrel_p2p, you tune HyParView's two main parameters; there is
no other topology to choose:

```erlang
{barrel_p2p, [
    {active_size, 5},
    {passive_size, 30}
]}
```

If you want a non-HyParView topology, barrel_p2p is not the right
library.

## How service discovery works

Partisan does not ship service discovery. You can build it on top
of `partisan_plumtree_backend` (the upstream broadcast layer) or
integrate an external registry like Consul.

Barrel P2P ships a service registry:

```erlang
%% Register
barrel_p2p:register_service(my_service, #{version => "1.0"}).

%% Discover anywhere in the cluster
{ok, _Node, Pid} = barrel_p2p:whereis_service(my_service).

%% Subscribe to changes
barrel_p2p:subscribe_services().
```

The registry is a CRDT (an Observed-Remove Map). Adds and
removes commute; multiple replicas converge without coordination.
A registration on node A is visible from node B within a fraction
of a second.

## When to pick barrel_p2p

If you can answer "yes" to two or more of these, barrel_p2p is
probably the right choice:

- "I want service discovery in the box, not as a separate
  service."
- "I want `Pid ! Msg`, `gen_server`, and `global` to work
  normally."
- "I prefer opinionated defaults to a large configuration
  surface."
- "I want encryption between peers by default, with no extra
  setup."
- "I want a small cluster (10–500 nodes) with secure peer
  identity."

Barrel P2P is a good fit for microservice-style applications that
need to discover sibling services by name, applications migrating
off the full-mesh dist into a partial-membership topology, and
internal tools that want a secure dist without standing up a CA.

## When to pick Partisan

If you can answer "yes" to two or more of these, Partisan is
probably the right choice:

- "I need multiple topologies (full mesh for one cluster,
  client-server for another, custom for a third)."
- "I need explicit channels with different parallelism for
  different message classes."
- "I am experimenting with distributed protocols and want a
  research-friendly toolkit."
- "I am willing to build service discovery on top of broadcast."
- "TCP is fine; I do not need encryption between peers in the
  framework itself."

Partisan is a good fit for research platforms, applications
needing multiple topology modes simultaneously, and systems where
explicit channel control is part of the design.

## Migration sketches

### Partisan to barrel_p2p

Membership calls change:

```erlang
%% Partisan
partisan_peer_service:join(Node).
partisan_peer_service:members().

%% Barrel P2P
barrel_p2p:join(Node).
barrel_p2p:active_view().
```

Message forwarding becomes service discovery plus a normal send:

```erlang
%% Partisan
partisan_peer_service:forward_message(Node, Msg).

%% Barrel P2P
{ok, _Node, Pid} = barrel_p2p:whereis_service(target_service),
Pid ! Msg.
```

Channels disappear; everything goes through standard Erlang
distribution. If you depended on channel parallelism for
throughput, the carrier already provides it: barrel_p2p's QUIC
connection routes distribution messages across a pool of streams,
hashing each `{From, To}` process pair onto its own stream (the
control stream stays separate and highest priority). Independent
process pairs run in parallel without head-of-line blocking, with
no channels to declare.

### Barrel P2P to Partisan

You will need to write or wire in a service-discovery story.
Either build one on top of Partisan's broadcast layer, or
integrate an external service registry, depending on what you
need.

Membership calls and message-forwarding APIs both change; expect
to touch most code paths that talk across the cluster.

## Performance shape

A direct comparison is not particularly meaningful: the two
projects optimise for different shapes of workload. A few
qualitative notes:

- **Connection count.** Partisan with full-mesh keeps O(n^2)
  connections; barrel_p2p and Partisan-with-HyParView keep O(n log n).
- **Encryption.** Barrel P2P is encrypted by default (QUIC).
  Partisan adds TLS on top of TCP only when you opt in.
- **Service-lookup latency.** Barrel P2P's registry hits the local
  CRDT cache for known services; Partisan's depends on what you
  built on top of broadcast.
- **Broadcast cost.** Both projects can use Plumtree; the algorithm
  is the same. Barrel P2P ships it integrated; Partisan ships it as
  one of several broadcast modules.
- **Stream parallelism.** barrel_p2p's QUIC carrier hashes each
  `{From, To}` process pair onto its own stream from a per-connection
  pool, so independent flows do not head-of-line block one another
  and control traffic is prioritised above data. This is automatic;
  Partisan reaches the same parallelism through channels you declare
  and route messages onto explicitly.

Pick by feature fit, not by performance benchmark. Both projects
scale to clusters of hundreds of nodes.

## Summary

| If you need...                          | Use      |
|----------------------------------------|----------|
| Built-in service discovery              | Barrel P2P |
| Multiple topology backends              | Partisan |
| Standard `Pid ! Msg` and `gen_server`   | Barrel P2P |
| Explicit per-class message channels     | Partisan |
| Automatic per-pair stream parallelism   | Barrel P2P |
| Minimal configuration                   | Barrel P2P |
| Maximum flexibility                     | Partisan |
| QUIC transport + Ed25519 in the box     | Barrel P2P |
| TCP + your own protocols                | Partisan |
| Production service mesh on Erlang       | Either   |
