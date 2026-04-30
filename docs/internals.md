# Mycelium Internals

This document covers the internal architecture, protocols, and implementation details of Mycelium. It's intended for contributors and advanced users who want to understand how the system works.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application                              │
│    mycelium:join/1  mycelium:register_service/2  whereis_service │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────┴─────────────────────────────────┐
│                        mycelium.erl (API)                        │
└───────────────────────────────┬─────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   HyParView   │     │ Service Registry │     │    Plumtree     │
│   Membership  │     │   (OR-Map CRDT)  │     │   Broadcast     │
└───────┬───────┘     └────────┬────────┘     └────────┬────────┘
        │                      │                       │
        └──────────────────────┼───────────────────────┘
                               │
                    ┌──────────┴──────────┐
                    │   mycelium_bridge   │
                    │ (Erlang Distribution)│
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │    mycelium_dist    │
                    │ (proto_dist module) │
                    │  Ed25519 + QUIC     │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │   erlang_quic       │
                    │ (transport library) │
                    └─────────────────────┘
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

Peers are identified by their **key fingerprint** (SHA-256 hash of the public key), not by node name. This allows:
- Same keypair across hostname changes
- Key migration between machines
- Cryptographic identity verification

### Key Storage

```erlang
%% Keys stored by mycelium_dist_keys (keyed by fingerprint)
-record(peer_key, {
    fingerprint :: binary(),       %% SHA-256 hash of public_key (32 bytes)
    public_key  :: binary(),       %% 32 bytes Ed25519 public key
    added_at    :: integer(),      %% Timestamp
    last_seen   :: integer(),      %% Last connection
    trust_level :: permanent | tofu
}).
```

Keys are persisted to disk in `data/keys/trusted/<fingerprint-prefix>.pub` using format:
```
mycelium-ed25519 <base64-encoded-public-key>
```

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

Mycelium owns its `proto_dist` module: `mycelium_dist`. Selected
with `-proto_dist mycelium` (OTP appends the `_dist` suffix). The
carrier wraps `erlang_quic` and runs an Ed25519 challenge-response
on a dedicated unidirectional auth stream pair before
`dist_util:handshake_*` runs. The same QUIC connection multiplexes
the dist control stream and any circuit user streams.

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

## Router and Overlay Routing

`mycelium_router` provides multi-hop routing through the overlay.

### Route Discovery

```erlang
%% Find path to target node
{ok, Path} = mycelium_router:find_route(TargetNode).
%% Path = [Hop1, Hop2, ..., TargetNode]
```

### Routing Algorithm

1. Check if target is in active view (direct connection)
2. Query active peers for routes to target
3. Cache successful routes (30-minute TTL)

### Route Messages

```erlang
%% Route query
{route_query, Target, TTL, QueryId, ReplyTo}

%% Route response
{route_reply, Target, Path, QueryId}
```

### Service Proxy

`mycelium_service_proxy` uses routing for transparent RPC:

```erlang
%% whereis_service uses proxy for remote services
{ok, Pid} = mycelium:whereis_service(remote_service).
%% Pid is local proxy that forwards to remote node
```

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

## Circuit Routing Architecture

Circuit routing provides multi-hop encrypted channels. See [Circuit Routing](circuits.md) for usage; this section covers internals.

### Supervision Structure

```
mycelium_circuit_sup (one_for_one)
│
├── mycelium_circuit_metrics (worker)
│   └── ETS-based metrics collection
│
├── mycelium_circuit_relay (gen_server)
│   └── Manages relay hop state
│
├── mycelium_circuit_transport_quic (worker)
│   └── User-stream multiplexer over the per-peer mycelium_dist
│       QUIC connection. Circuits ride the same connection that
│       carries the Erlang distribution channel.
│
├── mycelium_circuit_relay_masque (worker)
│   └── HTTP/3 CONNECT-UDP relay fallback when direct UDP and
│       hole-punching both fail.
│
└── circuit processes (dynamic)
    └── mycelium_circuit (gen_statem)
        └── Individual circuit state machine
```

### Circuit State Machine

Each circuit is managed by a `gen_statem` process with three states:

```
                    ┌─────────────────┐
                    │    building     │
     CREATE sent    │                 │
     ────────────►  │  Waiting for    │
                    │  CREATED/       │
                    │  EXTENDED       │
                    └────────┬────────┘
                             │ EXTENDED received
                             │ (or CREATED for direct)
                             ▼
                    ┌─────────────────┐
                    │     ready       │
                    │                 │
                    │  Encrypt/send   │◄── DATA
                    │  Decrypt/recv   │
                    │                 │
                    └────────┬────────┘
                             │ close() or DESTROY
                             ▼
                    ┌─────────────────┐
                    │    closing      │
                    │                 │
                    │  Cleanup        │
                    └─────────────────┘
```

### Protocol Messages

| Message | Format | Purpose |
|---------|--------|---------|
| CREATE | `{create, circuit_id, eph_pub_key}` | Establish circuit hop |
| CREATED | `{created, circuit_id, eph_pub_key}` | Acknowledge, return key |
| EXTEND | `{extend, circuit_id, target, eph_pub_key}` | Extend to next hop |
| EXTENDED | `{extended, circuit_id, eph_pub_key}` | Extension complete |
| DATA | `{data, circuit_id, encrypted_payload}` | Application data |
| DESTROY | `{destroy, circuit_id, reason}` | Tear down circuit |

DESTROY reason codes:
- `0` - Normal close
- `1` - Timeout/expired
- `2` - Decryption failure

### Relay Operation

`mycelium_circuit_relay` maintains hop state in ETS:

```erlang
-record(circuit_hop, {
    circuit_id   :: #circuit_id{},
    prev_node    :: node(),      %% Backward direction
    next_node    :: node(),      %% Forward direction
    created_at   :: integer(),
    last_active  :: integer()
}).
```

When a DATA message arrives:
1. Lookup hop state by circuit_id
2. Forward to next_node (if forward) or prev_node (if backward)
3. Update last_active timestamp
4. No decryption (relay sees opaque blob)

### Encryption

Circuit encryption uses X25519 for key exchange and ChaCha20-Poly1305 for AEAD:

```erlang
-record(crypto_session, {
    send_key     :: binary(),    %% 32 bytes
    recv_key     :: binary(),    %% 32 bytes
    send_nonce   :: integer(),   %% Counter
    recv_nonce   :: integer()
}).
```

Key derivation:
```
shared_secret = X25519(our_private, their_public)
keys = HKDF-SHA256(shared_secret, initiator_pub || dest_pub)
initiator_send_key = keys[0:32]
dest_send_key = keys[32:64]
```

### Metrics Internals

`mycelium_circuit_metrics` uses two ETS tables:

1. **Counters table** (write_concurrency):
   - `circuits_created`, `circuits_established`, etc.
   - Per-role breakdowns: `{circuits_created, initiator}`
   - Latency histogram buckets

2. **Latency samples** (ordered_set):
   - Ring buffer of recent samples (max 1000)
   - Used for percentile calculations
   - Keyed by `{timestamp, ref}` for ordering

Metrics are lock-free using `ets:update_counter/3`
