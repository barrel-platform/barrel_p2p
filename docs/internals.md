# Mycelium Internals

This document covers the internal architecture, protocols, and implementation details of Mycelium. It's intended for contributors and advanced users who want to understand how the system works.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                            Application                                │
│  mycelium:join/1  register_service/2  whereis_service  circuit_open  │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────┴──────────────────────────────────────┐
│                          mycelium.erl (API)                           │
└──────┬──────────────┬────────────────┬────────────────┬──────────────┘
       │              │                │                │
       ▼              ▼                ▼                ▼
┌────────────┐ ┌────────────┐  ┌──────────────┐ ┌────────────────┐
│  HyParView │ │  Registry  │  │   Plumtree   │ │ Circuits v2    │
│ Membership │ │ (OR-Map)   │  │  Broadcast   │ │ (mycelium_     │
│            │ │            │  │              │ │  circuit*)     │
└─────┬──────┘ └──────┬─────┘  └──────┬───────┘ └────────┬───────┘
      │               │               │                  │
      │               │               │                  ▼
      │               │               │         ┌────────────────┐
      │               │               │         │ mycelium_      │
      │               │               │         │  router        │
      │               │               │         │ (RTT paths)    │
      │               │               │         └────────┬───────┘
      │               │               │                  │
      └───────────────┴───────────────┴──────┬───────────┘
                                             ▼
                                  ┌────────────────────┐
                                  │ mycelium_streams   │
                                  │ (tagged user-      │
                                  │  stream multiplex) │
                                  └─────────┬──────────┘
                                            │
                                  ┌─────────┴──────────┐
                                  │  mycelium_dist     │
                                  │ (alt-dist shim:    │
                                  │  cert + defaults)  │
                                  └─────────┬──────────┘
                                            │
                                  ┌─────────┴──────────┐
                                  │ quic_dist (upstream)│
                                  │  + auth_callback    │
                                  │  + discovery_module │
                                  │  + register_with_   │
                                  │    epmd             │
                                  └─────────┬──────────┘
                                            │
                                  ┌─────────┴──────────┐
                                  │   erlang_quic      │
                                  │ (transport library) │
                                  └────────────────────┘
```

## Supervision Tree

```
mycelium_sup (one_for_one)
│
├── mycelium_hlc (worker)
│   └── Hybrid Logical Clock for timestamps
│
├── mycelium_dist_keys (worker)
│   └── Ed25519 key management
│
├── mycelium_hyparview_sup (supervisor, rest_for_one)
│   ├── mycelium_hyparview (gen_server)
│   │   └── HyParView protocol state machine
│   ├── mycelium_hyparview_events (gen_server)
│   │   └── Event subscription/notification
│   ├── mycelium_hyparview_shuffle (worker)
│   │   └── Periodic shuffle timer
│   └── mycelium_hyparview_cleanup (worker)
│       └── Passive view age-based cleanup
│
├── mycelium_plumtree_sup (supervisor)
│   └── mycelium_plumtree (gen_server)
│       └── Epidemic broadcast tree
│
├── mycelium_registry_sup (supervisor, rest_for_one)
│   ├── mycelium_registry (gen_server)
│   │   └── Local service registry with CRDT
│   └── mycelium_registry_sync (gen_server)
│       └── Registry replication via Plumtree
│
├── mycelium_proxy_sup (simple_one_for_one)
│   └── mycelium_service_proxy (gen_server, dynamic)
│       └── Remote service proxies
│
├── mycelium_router (gen_server)
│   └── RTT-aware path discovery (mycelium_path_cache ETS)
│
├── mycelium_streams (gen_server)
│   └── Single tagged-stream acceptor; demuxes user streams by tag
│
├── mycelium_circuit_sup (supervisor)
│   └── mycelium_circuit_relay (gen_server)
│       └── Acceptor for <<"mycelium:circuit">> streams; splices
│           relay-role hops, dispatches endpoint pipes
│
└── mycelium_bridge (gen_server)
    └── Erlang distribution connection manager
```

## HyParView Protocol

HyParView (Hybrid Partial View) is a protocol for maintaining partial network membership. Each node maintains two views:

### Active View

- Small set of currently connected peers (default: 5)
- Symmetric connections (if A has B, B has A)
- Used for Plumtree broadcast tree

### Passive View

- Larger set of known but unconnected peers (default: 30)
- Used as backup when active connections fail
- Refreshed through periodic shuffle

### Protocol Messages

```erlang
%% Join request to contact node
{join, #peer{id = node(), address = IP, port = Port}}

%% Forward join through the network
{forward_join, NewPeer :: #peer{}, TTL :: integer(), Sender :: #peer{}}

%% Graceful disconnect
{disconnect, #peer{}}

%% Request to become neighbor (after connection loss)
{neighbor, Priority :: high | low, #peer{}}
{neighbor_reply, Accept :: boolean(), #peer{}}

%% Periodic view exchange
{shuffle, TTL :: integer(), Peers :: [#peer{}], Sender :: #peer{}}
{shuffle_reply, Peers :: [#peer{}], Sender :: #peer{}}
```

### Join Process

1. New node sends `join` to contact node
2. Contact node adds new node to active view
3. Contact node sends `forward_join` to random active peer
4. `forward_join` propagates with decreasing TTL (ARWL)
5. At TTL=0 or PRWL, receiving node adds new node to active/passive view

```
NewNode ──join──► ContactNode
                      │
                      ├──forward_join(ttl=6)──► NodeA
                      │                            │
                      │                            ├──forward_join(ttl=5)──► NodeB
                      │                            │                            │
                      │                            │                            └─► ...
```

### Shuffle Process

Periodic exchange refreshes views and maintains connectivity:

1. Node picks random peer from active view
2. Sends `shuffle` with subset of active + passive peers
3. Receiver merges received peers into passive view
4. Receiver replies with subset of its peers
5. Originator merges reply into passive view

### Failure Handling

When a connection fails:

1. Node is moved from active to a "failed" state
2. Exponential backoff prevents reconnection storms
3. After max failures, node is moved to passive view
4. Replacement is selected from passive view using `neighbor` request

```erlang
-record(peer, {
    id            :: node(),
    fail_count    = 0 :: non_neg_integer(),
    backoff_until :: integer() | undefined
}).
```

## OR-Map CRDT for Service Registry

The service registry uses an Observed-Remove Map (OR-Map) CRDT for conflict-free replication.

### Data Structure

```erlang
%% OR-Map: Key -> {Dots, Values}
%% Dots track which updates we've seen
%% Values are tagged with their originating dot

-type dot() :: {node(), hlc:timestamp()}.
-type or_map() :: #{
    Key => {
        dots :: sets:set(dot()),
        values :: [{dot(), Value}]
    }
}.
```

### Operations

**Add**: Creates a new dot and adds value
```erlang
add(Key, Value, Node, HLC, ORMap) ->
    Dot = {Node, hlc:now(HLC)},
    %% Add new entry tagged with dot
    ...
```

**Remove**: Removes all current values (observed remove)
```erlang
remove(Key, ORMap) ->
    %% Remove only dots we've observed
    %% New concurrent adds are preserved
    ...
```

**Merge**: Combines two OR-Maps
```erlang
merge(Map1, Map2) ->
    %% Union of dots
    %% Keep values with unremoved dots
    ...
```

### Replication Flow

```
Node A: register_service(foo)
        │
        ├──► mycelium_registry adds to local OR-Map
        │
        ├──► mycelium_registry_sync creates delta
        │
        └──► mycelium_plumtree broadcasts delta
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
     Node B                  Node C
     merge(delta)            merge(delta)
```

## Plumtree Broadcast

Plumtree (Push-Lazy-Push Multicast Tree) provides efficient epidemic broadcast.

### Components

**Eager Peers**: Receive messages immediately via push
**Lazy Peers**: Receive only message IDs; request full message if needed

### Message Flow

```
Broadcast origin
      │
      ├─eager─► Peer A ─eager─► Peer C
      │              └─lazy──► Peer D
      │
      └─eager─► Peer B ─eager─► Peer E
```

### Protocol Messages

```erlang
%% Push full message
{gossip, MessageId, Payload, Round}

%% Lazy announcement (message ID only)
{ihave, MessageId, Round}

%% Request missing message
{graft, MessageId}

%% Demote to lazy peer
{prune}
```

### Tree Construction

1. Initially all active peers are eager
2. Duplicate messages cause `prune` (sender becomes lazy)
3. Missing messages (ihave but no gossip) cause `graft`
4. Tree self-organizes to minimize redundancy

### GRAFT Repair

If a node receives `ihave` but not the actual message:

1. Wait brief timeout for gossip
2. If not received, send `graft` to lazy peer
3. Lazy peer becomes eager, retransmits message

This self-healing ensures reliable delivery despite tree inconsistencies.

## Hybrid Logical Clocks

Mycelium uses Hybrid Logical Clocks (HLC) for causally consistent timestamps.

### Properties

- Monotonically increasing per node
- Captures causal ordering across nodes
- Compatible with wall clock (for human readability)

### Structure

```erlang
-record(hlc, {
    wall_time :: integer(),  %% Physical time
    logical   :: integer(),  %% Logical counter
    node      :: node()      %% Node identifier
}).
```

### Operations

```erlang
%% Generate new timestamp
Timestamp = mycelium_hlc:now().

%% Update clock after receiving message
mycelium_hlc:update(ReceivedTimestamp).

%% Compare timestamps
case mycelium_hlc:compare(T1, T2) of
    lt -> T1 happened before T2;
    gt -> T1 happened after T2;
    eq -> Same timestamp
end.
```

### Usage in CRDT

HLC timestamps are used as dots in the OR-Map:

```erlang
Dot = {node(), hlc:now(HLC)}
%% Globally unique, causally ordered
```

## Ed25519 Authentication

Mycelium uses Ed25519 public-key cryptography to authenticate peer connections. See [Authentication](authentication.md) for detailed provisioning and key management.

### Key Identity

Each trusted peer is stored under its **node atom**: lookup, store,
and delete (`mycelium_dist_keys:lookup_key/1`, `store_key/2`,
`delete_key/1`) all take a node atom. `mycelium_dist_keys:fingerprint/1`
returns the SHA-256 of a public key for log lines and key-mismatch
diagnostics.

### Key Storage

```erlang
%% Keys stored by mycelium_dist_keys (ETS keyed by #peer_key.node).
-record(peer_key, {
    node        :: node() | undefined,    %% Primary key
    fingerprint :: binary() | undefined,  %% SHA-256 of public_key
    public_key  :: binary(),              %% 32 bytes Ed25519 public key
    added_at    :: integer(),             %% Timestamp (ms)
    last_seen   :: integer(),             %% Last connection (ms)
    trust_level :: permanent | tofu
}).
```

Permanent and TOFU keys are persisted to
`data/keys/trusted/<node-atom>.pub` as the raw 32-byte public key
binary.

### Trust Modes

| Mode | Unknown Key | Known Key Match | Known Key Mismatch |
|------|-------------|-----------------|-------------------|
| `tofu` | Accept & store | Accept | Reject |
| `strict` | Reject | Accept | Reject |

### Authentication Flow

```
Node A (initiator)                    Node B (acceptor)
       │                                     │
       ├─── HELLO(pubkey_A, node_A) ────────►│
       │                                     │
       │◄── HELLO(pubkey_B, node_B) ─────────┤
       │                                     │
       ├─── CHALLENGE(nonce_A) ─────────────►│
       │                                     │
       │◄── CHALLENGE(nonce_B) ──────────────┤
       │                                     │
       ├─── RESPONSE(sign(nonce_B)) ────────►│
       │                                     │
       │◄── RESPONSE(sign(nonce_A)) ─────────┤
       │                                     │
                   Authenticated
```

### Configuration

```erlang
{mycelium, [
    {auth_enabled, true},           %% Enable/disable auth
    {auth_trust_mode, tofu},        %% tofu | strict
    {auth_key_dir, "data/keys"}     %% Key storage directory
]}
```

### Key Management API

```erlang
%% Store a peer's key (for strict mode)
mycelium_dist_keys:store_key(Node, PubKey).

%% List trusted peers
mycelium_dist_keys:list_trusted().

%% Check if a peer's presented key is trusted
mycelium_dist_keys:is_trusted(Node, PubKey).

%% Get this node's public key
{ok, MyPubKey} = mycelium_dist_auth:get_public_key().
```

## Distribution Carrier

Boot with `-proto_dist mycelium -epmd_module mycelium_epmd
-start_epmd false`. The carrier opens a single QUIC connection per
peer and carries the Erlang distribution channel on it.

`mycelium_dist` is a thin alt-dist shim over upstream `quic_dist`.
At `listen/1` it auto-generates the TLS material (`data/quic/
node.{crt,key}`) if missing and projects three defaults into the
`{quic, dist, ...}` app env before delegating:

- `auth_callback => {mycelium_dist_auth_callback, authenticate}` runs
  the Ed25519 challenge-response on a uni-stream pair between the
  QUIC handshake and the dist `handshake_we_started`/`handshake_other_started`.
  The callback returns `{ok, NodeAtom}` on success or `{error, Reason}`;
  on error the connection is closed and the dist controller never
  starts.
- `discovery_module => mycelium_discovery` is a composing dispatcher
  that fans out to a configurable backend chain (default:
  `mycelium_discovery_static` for the `{quic, [{dist, [{nodes, ...}]}]}`
  map, `mycelium_discovery_file` for an on-disk endpoint registry under
  `data/discovery/<node>.endpoint`, and `mycelium_discovery_dns` for
  the DNS host fallback). Lookups try each backend in order; first
  hit wins. Registration fans out so a node's filesystem entry is
  visible to siblings on the same host with no stock-EPMD daemon.
- `mycelium_app:start/2` itself republishes the node into the
  discovery chain once sys.config envs are live, using the full atom
  node name; the listen-time register-with-epmd path is left
  disabled so the bare name string never reaches the file backend.

User-supplied values under `{quic, [{dist, [...]}]}' or
`-quic_dist_*' init args win over these defaults; the shim only
fills in keys the user didn't set.

NAT traversal is out of scope. When a direct path is unavailable,
`quic_dist:set_connect_options/2` lets callers register a per-peer
connect-time override (e.g. `#{socket_backend => adapter,
socket_adapter => Adapter}`) that the next `setup/5` consumes. See
[external-relay.md](external-relay.md).

```erlang
%% Configuration
{mycelium, [
    {listen_port, 9100},
    {auth_enabled, true},
    {auth_trust_mode, tofu}
]}
```

### Connection Management

`mycelium_bridge` manages distribution connections:

1. Monitors active view changes from HyParView
2. Establishes connections to new peers
3. Closes connections when peers leave active view
4. Handles connection failures with retry logic

## Tagged Stream Multiplex

`mycelium_streams` is the single user-stream acceptor on every node.
It demultiplexes incoming `quic_dist` user streams by a length-prefixed
tag and hands ownership to the registered handler.

### Wire preamble

Every mycelium-managed user stream starts with:

```
<<TagLen:8, Tag:TagLen/binary, Payload/binary>>
```

Reserved tags:

- `<<"mycelium:circuit">>` — circuit traffic (handled by
  `mycelium_circuit_relay`)
- `<<"mycelium:", _/binary>>` — reserved for future internals

Applications use any other tag (`<<"chat:rooms">>`, `<<"acme.kv">>`).

### API

```erlang
mycelium_streams:register_acceptor(Tag, Pid).
mycelium_streams:open(Tag, Node) -> {ok, StreamRef}.
```

After `open/2` returns, the caller owns the underlying `quic_dist`
stream and uses `quic_dist:send/2,3` and `close_stream/1` directly —
the demuxer is off the data path. The acceptor pid receives one
`{mstream, StreamRef, opened, FromNode}` message and then native
`{quic_dist_stream, StreamRef, _}` events.

## Router and Multi-hop Path Selection

`mycelium_router` discovers RTT-aware paths through the overlay for
both circuit setup and overlay RPC.

### Path stats

`mycelium_path_stats:srtt/1` wraps `quic:get_path_stats/1` (upstream)
to return the smoothed RTT (microseconds) on the QUIC connection
backing each peer's dist channel. Each forwarding peer contributes
its local `srtt(NextHop)` to a probe accumulator.

### Find-path

```erlang
{ok, Path, EstRttUs} = mycelium_router:find_path(Target).
{ok, Path, EstRttUs} = mycelium_router:find_path(Target,
    #{max_hops => 4, exclude => [DeadHop], timeout => 200}).
```

Algorithm:

1. `Target =:= node()` -> `{ok, [], 0}`.
2. `Target` in active view -> `{ok, [], srtt(self, Target)}`.
3. Otherwise broadcast `?route_probe` to active peers (excluding
   `exclude`); each forwarder adds `srtt(NextHop)` to the accumulator
   before relaying; terminal peers reply with `{Path, AccRtt}`.
4. Initiator picks the lowest-AccRtt reply, adds its own `srtt` to
   the responder, caches in `mycelium_path_cache` (separate from the
   service-name `mycelium_route_cache`).

### Service Proxy

`mycelium_service_proxy` uses routing for transparent RPC:

```erlang
{ok, Pid} = mycelium:whereis_service(remote_service).
%% Pid is local proxy that forwards to remote node
```

## Circuits v2

`mycelium_circuit:open/1,2` builds a stream-shaped channel between
two cluster nodes that may not be in each other's active view. Layered
on `mycelium_streams` with the reserved tag `<<"mycelium:circuit">>`.

### Layers

1. `mycelium_streams` — tagged user-stream multiplex (above).
2. `mycelium_circuit_proto` — five frames: `CREATE`, `RESUME`,
   `DATA(Seq:48, Len:32, Payload)`, `ACK(CumSeq:48)`, `FIN(Seq:48)`.
3. `mycelium_circuit_link` — windowed reliability (per-direction
   `tx_unacked_buffer`, `rx_next_expected`, cumulative ACKs, replay
   on RESUME). Both DATA and FIN consume one sequence number.
4. `mycelium_circuit_pipe` — endpoint owner; one pipe per circuit
   end, drives the link, exposes `{circuit, CRef, _}` events to the
   caller.
5. `mycelium_circuit_relay` — singleton acceptor; relay-role hops
   splice bytes between two streams without per-circuit state.

### Byte-perfect migration

When an intermediate hop's stream dies, the initiator-side pipe asks
the router for a fresh path (excluding the dead hop), opens a new
circuit stream, and writes `FRAME_RESUME(CircuitId, RxNext,
NewPath)`. Relays on the new path treat RESUME like CREATE for
routing — they pop the head of `NewPath`, open the next downstream,
and rewrite RESUME with the tail. The destination matches by
`CircuitId`, attaches the new stream to the existing pipe, and writes
its own symmetric `FRAME_RESUME` back upstream. Both sides prune
their unacked buffers (drop frames with `Seq < peer's RxNext`) and
replay the remainder preserving original frame type (DATA vs FIN).
No bytes are lost.

### Auto-routing

`open/1` (no path) calls `mycelium_router:find_path/1` — the lowest
RTT path is picked automatically. `open/2` accepts an explicit path
or an options map `#{path => P, repath => false, max_hops => N}`.

## Performance Tuning

### HyParView Parameters

| Parameter | Effect of Increase | Effect of Decrease |
|-----------|-------------------|-------------------|
| `active_size` | More connectivity, more overhead | Less redundancy, faster convergence |
| `passive_size` | More backup options | Smaller memory footprint |
| `shuffle_period` | Less network traffic | Slower view refresh |
| `arwl` | Better join distribution | Faster join completion |

### Recommended Settings

**Small cluster (< 50 nodes)**
```erlang
{active_size, 3},
{passive_size, 15}
```

**Medium cluster (50-500 nodes)**
```erlang
{active_size, 5},
{passive_size, 30}
```

**Large cluster (500+ nodes)**
```erlang
{active_size, 7},
{passive_size, 50}
```

### Monitoring

Key metrics to monitor:

- Active view size (should stay near `active_size`)
- Passive view size (should grow but stay bounded)
- Shuffle success rate
- Service lookup latency
- Route cache hit rate

