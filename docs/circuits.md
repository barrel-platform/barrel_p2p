# Circuit Routing

Circuit routing enables secure, multi-hop communication channels through the Mycelium network. Circuits provide end-to-end encryption where intermediate relay nodes cannot read the traffic.

## Overview

A circuit is an encrypted tunnel from an initiator node to a destination node, optionally passing through one or more relay nodes. Key properties:

- **End-to-end encryption**: Only the initiator and destination can read the data
- **Relay privacy**: Intermediate hops forward opaque encrypted blobs
- **Ephemeral keys**: Each circuit uses unique X25519 keys for forward secrecy
- **Automatic routing**: Relay hops are selected from the HyParView membership

### When to Use Circuits

| Use Case | Recommended |
|----------|-------------|
| Sensitive data between known peers | Yes |
| Anonymous communication | Yes (multiple hops) |
| High-throughput bulk transfer | No (use direct connections) |
| Real-time low-latency messaging | No (circuit setup adds latency) |

### Connection Path Selection

Mycelium automatically selects the best path to reach a target, considering NAT traversal and direct reachability:

```
                        ┌─────────────────────────────────────────┐
                        │         Path Selection Flow             │
                        └─────────────────────────────────────────┘

┌─────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌──────────────┐
│ Circuit │────►│ Direct Reachable?│─Yes─►│  Direct Path    │────►│ 0-hop Circuit│
│ Create  │     │ (Active/Nodes)   │     │  (No Relay)     │     │ (Encrypted)  │
└─────────┘     └──────────────────┘     └─────────────────┘     └──────────────┘
                        │ No
                        ▼
                ┌──────────────────┐     ┌─────────────────┐     ┌──────────────┐
                │ NAT Compatible?  │─Yes─►│  Hole Punch     │─OK─►│ Direct UDP   │
                │ (Cache lookup)   │     │  Attempt        │     │ Connection   │
                └──────────────────┘     └─────────────────┘     └──────────────┘
                        │ No                     │ Fail
                        ▼                        ▼
                ┌──────────────────┐     ┌─────────────────┐     ┌──────────────┐
                │  Select Relays   │────►│  Multi-hop      │────►│ Relay Circuit│
                │  from HyParView  │     │  Circuit        │     │ (N hops)     │
                └──────────────────┘     └─────────────────┘     └──────────────┘
```

#### Step 1: Direct Reachability Check

First, Mycelium checks if the target is directly reachable without NAT traversal:

| Check | Method | Result if True |
|-------|--------|----------------|
| Active view | Target in HyParView active view | Direct path |
| Erlang nodes | Target in `nodes()` | Direct path |
| Dist probe | `net_kernel:connect_node/1` with bounded timeout | Direct path |

```erlang
%% Direct path results in 0-hop circuit (still encrypted)
{ok, CircuitId} = mycelium:circuit_create('target@host').
%% If target is reachable, circuit uses direct connection
```

#### Step 2: NAT Compatibility Check

If direct connection fails, check NAT compatibility:

```
┌─────────────┐                              ┌─────────────┐
│   Node A    │                              │   Node B    │
│ NAT: port   │                              │ NAT: full   │
│ restricted  │                              │    cone     │
└──────┬──────┘                              └──────┬──────┘
       │                                            │
       │         ┌──────────────────┐              │
       └────────►│  NAT Cache       │◄─────────────┘
                 │  Lookup Types    │
                 └────────┬─────────┘
                          │
                          ▼
                 ┌──────────────────┐
                 │ is_viable(       │
                 │   port_restricted│────► true (can punch)
                 │   full_cone)     │
                 └──────────────────┘
```

NAT info is exchanged via the hello protocol and cached:

```erlang
%% Check if hole punch is viable
case mycelium_nat_cache:get_peer_nat(Target) of
    {ok, #nat_info{nat_type = PeerNat}} ->
        LocalNat = mycelium_nat:get_nat_type(),
        mycelium_hole_punch:is_viable(LocalNat, PeerNat);
    {error, _} ->
        unknown  %% Try hole punch anyway
end.
```

#### Step 3: Hole Punch or Relay

Based on NAT compatibility:

**Compatible NATs (hole punch viable):**
```
┌─────────────┐                              ┌─────────────┐
│   Node A    │                              │   Node B    │
│  Internal:  │         ┌────────┐           │  Internal:  │
│ 192.168.1.10│◄────────│  NAT   │◄──────────│ 10.0.0.20   │
│  External:  │────────►│Gateway │──────────►│  External:  │
│ 203.0.113.5 │         └────────┘           │198.51.100.8 │
└──────┬──────┘              │               └──────┬──────┘
       │                     │                      │
       │    UDP Hole Punch   │                      │
       │◄═══════════════════════════════════════════│
       │═══════════════════════════════════════════►│
       │         Direct UDP Connection              │
```

**Incompatible NATs (relay required):**
```
┌─────────────┐                              ┌─────────────┐
│   Node A    │                              │   Node B    │
│ NAT:symmetric│                             │ NAT:symmetric│
└──────┬──────┘                              └──────┬──────┘
       │                                            │
       │    ┌─────────┐    ┌─────────┐             │
       │───►│ Relay 1 │───►│ Relay 2 │─────────────│
       │◄───│         │◄───│         │◄────────────│
       │    └─────────┘    └─────────┘             │
       │           Encrypted Relay Path            │
```

### Direct Connection Optimization

When creating a circuit, Mycelium automatically checks if the target is directly reachable:

1. **Active view check**: If target is in HyParView active view, use direct connection
2. **Erlang nodes check**: If target is in `nodes()`, use direct connection
3. **Dist probe**: If not a neighbor, call `net_kernel:connect_node/1` with a bounded timeout. Mycelium owns the dist carrier (`mycelium_dist`) so a successful probe means the QUIC connection is up and the circuit can multiplex over it.
4. **NAT hole punch**: If the probe fails but NATs are compatible, attempt UDP hole punch
5. **MASQUE relay**: If hole punching also fails, fall back to a HTTP/3 CONNECT-UDP relay (`mycelium_circuit_relay_masque`) when `circuit_relay_uri` is configured

If direct connection is possible, the circuit uses zero relay hops (direct path), reducing latency and network overhead. If direct fails, it falls back to relay routing.

Probe results are cached to avoid repeated connection attempts:
- Successful probes cached for 5 minutes (configurable)
- Failed probes cached for 1 minute (configurable)

Disable probing with `{circuit_probe_direct, false}` in config.

### Same-NAT Optimization

When two nodes are behind the same NAT gateway (same external IP), they can communicate directly on the local network:

```
┌─────────────────────────────────────────────────────────┐
│                    NAT Gateway                          │
│                External: 203.0.113.1                    │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Local Network                       │   │
│  │                                                  │   │
│  │  ┌─────────┐         Direct         ┌─────────┐ │   │
│  │  │ Node A  │◄═══════════════════════│ Node B  │ │   │
│  │  │Internal:│      Local Traffic     │Internal:│ │   │
│  │  │.168.1.10│                        │.168.1.20│ │   │
│  │  └─────────┘                        └─────────┘ │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

Mycelium detects same-NAT scenarios by comparing external addresses and prefers host candidates for local network communication.

## Quick Start

### Creating a Circuit

```erlang
%% Create a circuit to target node with default options (2 hops)
{ok, CircuitId} = mycelium:circuit_create('target@host').

%% Create with custom options
{ok, CircuitId} = mycelium:circuit_create('target@host', #{
    hops => 3,           %% Number of intermediate relay nodes
    ttl => 1800000       %% Circuit lifetime in ms (30 minutes)
}).
```

### Sending and Receiving Data

```erlang
%% Send data through the circuit
ok = mycelium:circuit_send(CircuitId, <<"Hello, secure world!">>).

%% The initiator receives responses as messages:
receive
    {circuit_data, CircuitId, Data} ->
        io:format("Received: ~s~n", [Data])
end.
```

### Closing a Circuit

```erlang
%% Explicit close
mycelium:circuit_close(CircuitId).

%% Circuits also close automatically when TTL expires
```

## API Reference

### mycelium:circuit_create/1,2

Create a new circuit to a target node.

```erlang
-spec circuit_create(Target :: node()) -> {ok, CircuitId} | {error, Reason}.
-spec circuit_create(Target :: node(), Opts :: map()) -> {ok, CircuitId} | {error, Reason}.
```

**Options:**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `hops` | integer | 2 | Number of intermediate relay hops |
| `ttl` | integer | 3600000 | Circuit lifetime in milliseconds |

**Returns:**
- `{ok, CircuitId}` - Circuit ID to use for sending/receiving
- `{error, cannot_circuit_to_self}` - Cannot create circuit to local node
- `{error, not_enough_peers}` - Not enough peers available for requested hops

### mycelium:circuit_send/2

Send data through an established circuit.

```erlang
-spec circuit_send(CircuitId, Data :: binary()) -> ok | {error, Reason}.
```

**Returns:**
- `ok` - Data queued for transmission
- `{error, not_found}` - Circuit does not exist
- `{error, circuit_not_ready}` - Circuit still establishing

### mycelium:circuit_close/1

Close a circuit and release resources.

```erlang
-spec circuit_close(CircuitId) -> ok.
```

Always returns `ok`, even if circuit does not exist.

### mycelium:circuit_info/1

Get information about a circuit.

```erlang
-spec circuit_info(CircuitId) -> {ok, Info :: map()} | {error, not_found}.
```

**Info map fields:**
- `id` - Circuit identifier
- `role` - `initiator` or `destination`
- `target` - Target node
- `hops` - List of relay nodes
- `state` - `building` | `ready`
- `created_at` - Creation timestamp (monotonic)
- `expires_at` - Expiration timestamp (monotonic)

### mycelium:list_circuits/0

List all active circuits on this node.

```erlang
-spec list_circuits() -> [Info :: map()].
```

Returns a list of info maps (same format as `circuit_info/1`).

### mycelium:circuit_listen/0,1

Register to receive incoming circuit connections.

```erlang
-spec circuit_listen() -> ok | {error, already_listening}.
-spec circuit_listen(Pid :: pid()) -> ok | {error, already_listening}.
```

### mycelium:circuit_unlisten/0

Stop listening for incoming circuits.

```erlang
-spec circuit_unlisten() -> ok.
```

## Receiving Circuits (Destination)

To accept incoming circuits, a process must register as a listener:

```erlang
%% Register as circuit listener
ok = mycelium:circuit_listen().

%% Handle incoming circuit messages
loop() ->
    receive
        {circuit_ready, CircuitId} ->
            io:format("New circuit: ~p~n", [CircuitId]),
            loop();

        {circuit_data, CircuitId, Data} ->
            io:format("Data on ~p: ~p~n", [CircuitId, Data]),
            %% Send response back
            mycelium:circuit_send(CircuitId, <<"ACK">>),
            loop();

        {circuit_closed, CircuitId, Reason} ->
            io:format("Circuit ~p closed: ~p~n", [CircuitId, Reason]),
            loop()
    end.
```

Only one process per node can be the circuit listener. Call `circuit_unlisten/0` to release.

## Configuration

Configure circuit routing in your `sys.config`:

```erlang
{mycelium, [
    %% Circuit defaults
    {circuit_default_hops, 2},        %% Default relay hops for new circuits
    {circuit_default_ttl, 3600000},   %% Default TTL (1 hour)

    %% Resource limits
    {circuit_relay_max, 500},         %% Max circuits this node will relay
    {circuit_idle_timeout, 300000},   %% Idle circuit cleanup interval (5 min)

    %% Direct connection optimization
    {circuit_probe_direct, true},     %% Enable direct connection probing
    {circuit_probe_timeout, 500},     %% Dist connect_node probe timeout in ms
    {circuit_reachability_cache_ttl, 300000},    %% Cache TTL for successful probes (5 min)
    {circuit_reachability_negative_ttl, 60000},  %% Cache TTL for failed probes (1 min)

    %% NAT traversal (see docs/nat-traversal.md for details)
    {nat_enabled, true},              %% Enable NAT discovery
    {stun_servers, [                  %% STUN servers for NAT type detection
        {"stun.l.google.com", 19302}
    ]},
    {hole_punch_enabled, true},       %% Enable UDP hole punching
    {hole_punch_timeout, 10000},      %% Hole punch timeout in ms
    {upnp_enabled, true}              %% Enable UPnP/NAT-PMP port mapping
]}
```

### Configuration Reference

| Option | Default | Description |
|--------|---------|-------------|
| `circuit_default_hops` | 2 | Default number of intermediate relay hops |
| `circuit_default_ttl` | 3600000 | Default circuit lifetime in ms (1 hour) |
| `circuit_relay_max` | 500 | Maximum circuits this node will relay |
| `circuit_idle_timeout` | 300000 | Idle relay cleanup interval in ms (5 min) |
| `circuit_probe_direct` | true | Enable direct connection probing |
| `circuit_probe_timeout` | 500 | Dist connect_node probe timeout in ms |
| `circuit_reachability_cache_ttl` | 300000 | Cache TTL for successful probes in ms (5 min) |
| `circuit_reachability_negative_ttl` | 60000 | Cache TTL for failed probes in ms (1 min) |
| `nat_enabled` | true | Enable NAT type discovery via STUN |
| `stun_servers` | Google STUN | List of `{Host, Port}` STUN servers |
| `hole_punch_enabled` | true | Enable UDP hole punching |
| `hole_punch_timeout` | 10000 | Hole punch timeout in ms |
| `upnp_enabled` | true | Enable UPnP/NAT-PMP port mapping |

## Metrics and Monitoring

Circuit metrics are available via `mycelium_circuit_metrics:get_metrics/0`:

```erlang
#{
    circuits_created => 150,
    circuits_established => 145,
    circuits_failed => 5,
    circuits_closed => 120,
    circuits_active => 25,
    data_sent_bytes => 1048576,
    data_sent_count => 500,
    data_recv_bytes => 524288,
    data_recv_count => 250,
    latency => #{
        count => 145,
        avg_ms => 82.5,
        min_ms => 15,
        max_ms => 450,
        p50_ms => 65,
        p90_ms => 180,
        p99_ms => 350,
        histogram => #{10 => 5, 50 => 30, 100 => 60, ...}
    }
}
```

### Latency Statistics

```erlang
%% Get just latency stats
Stats = mycelium_circuit_metrics:get_latency_stats().
```

Returns percentiles (p50, p90, p99) and histogram buckets for circuit establishment latency.

### Failure Categories

Failed circuits are categorized:
- `timeout` - Establishment timeout (30s default)
- `transport_down` - Network connection failed
- `not_enough_peers` - Insufficient peers for requested hops
- `destroyed` - Remote end sent DESTROY
- `local_close` - Locally closed during establishment

## How It Works

### Circuit Establishment Flow

```
Initiator                 Relay A                  Relay B                 Destination
    │                        │                        │                        │
    │── CREATE(id, eph_pub) ─►│                        │                        │
    │                        │── CREATE ──────────────►│                        │
    │                        │                        │── CREATE ──────────────►│
    │                        │                        │                        │
    │                        │                        │◄── CREATED(eph_pub) ───│
    │                        │◄── EXTENDED ───────────│                        │
    │◄── EXTENDED ───────────│                        │                        │
    │                        │                        │                        │
    │                     CIRCUIT READY                                        │
    │                        │                        │                        │
    │══ DATA(encrypted) ════►│══ DATA ═══════════════►│══ DATA ═══════════════►│
    │                        │                        │                        │
    │◄══ DATA(encrypted) ════│◄══ DATA ═══════════════│◄══ DATA ═══════════════│
```

1. Initiator selects relay hops from HyParView membership
2. CREATE message sent to first hop with ephemeral public key
3. Each relay forwards CREATE to next hop
4. Destination generates its ephemeral keypair, sends CREATED back
5. EXTENDED propagates back to initiator
6. Both ends compute shared secret and derive session keys
7. DATA messages are encrypted end-to-end

### Protocol Messages

| Message | Direction | Purpose |
|---------|-----------|---------|
| `CREATE` | Forward | Establish circuit hop |
| `CREATED` | Backward | Acknowledge hop creation |
| `EXTEND` | Forward | Extend to next hop |
| `EXTENDED` | Backward | Acknowledge extension |
| `DATA` | Both | Encrypted application data |
| `DESTROY` | Both | Tear down circuit |

### Encryption Layers

Each circuit uses X25519 key exchange and ChaCha20-Poly1305 AEAD:

1. Initiator generates ephemeral keypair
2. Destination generates ephemeral keypair
3. Both compute shared secret via X25519
4. Session keys derived for each direction
5. All DATA payloads encrypted with ChaCha20-Poly1305

Relay nodes only see:
- Circuit ID
- Direction (forward/backward)
- Encrypted blob

## Examples

### Simple Echo Circuit

**Server (destination):**
```erlang
-module(circuit_echo_server).
-export([start/0]).

start() ->
    ok = mycelium:circuit_listen(),
    loop().

loop() ->
    receive
        {circuit_ready, CircuitId} ->
            io:format("Circuit ~p connected~n", [CircuitId]),
            loop();
        {circuit_data, CircuitId, Data} ->
            %% Echo back
            mycelium:circuit_send(CircuitId, Data),
            loop();
        {circuit_closed, CircuitId, Reason} ->
            io:format("Circuit ~p closed: ~p~n", [CircuitId, Reason]),
            loop()
    end.
```

**Client (initiator):**
```erlang
-module(circuit_echo_client).
-export([echo/2]).

echo(Target, Message) ->
    {ok, CircuitId} = mycelium:circuit_create(Target),
    receive
        {circuit_ready, CircuitId} ->
            mycelium:circuit_send(CircuitId, Message),
            receive
                {circuit_data, CircuitId, Response} ->
                    mycelium:circuit_close(CircuitId),
                    {ok, Response}
            after 5000 ->
                mycelium:circuit_close(CircuitId),
                {error, timeout}
            end;
        {circuit_failed, CircuitId, Reason} ->
            {error, Reason}
    after 30000 ->
        {error, establishment_timeout}
    end.
```

### Multi-hop Anonymous Routing

```erlang
%% Create circuit with 5 hops for stronger anonymity
{ok, CircuitId} = mycelium:circuit_create('destination@host', #{
    hops => 5,
    ttl => 600000  %% 10 minutes
}).
```

### Circuit Pool Pattern

For services that need multiple concurrent circuits:

```erlang
-module(circuit_pool).
-export([start/2, get_circuit/1, return_circuit/2]).

start(Target, PoolSize) ->
    Circuits = [begin
        {ok, C} = mycelium:circuit_create(Target),
        receive {circuit_ready, C} -> C after 30000 -> error end
    end || _ <- lists:seq(1, PoolSize)],
    {ok, spawn(fun() -> pool_loop(Circuits, []) end)}.

get_circuit(Pool) ->
    Pool ! {get, self()},
    receive {circuit, C} -> {ok, C} after 5000 -> {error, timeout} end.

return_circuit(Pool, Circuit) ->
    Pool ! {return, Circuit}.

pool_loop(Available, InUse) ->
    receive
        {get, From} when Available =/= [] ->
            [C | Rest] = Available,
            From ! {circuit, C},
            pool_loop(Rest, [C | InUse]);
        {return, C} ->
            pool_loop([C | Available], lists:delete(C, InUse));
        {circuit_closed, C, _} ->
            pool_loop(lists:delete(C, Available), lists:delete(C, InUse))
    end.
```

## Troubleshooting

### Circuit Establishment Failures

**`{error, not_enough_peers}`**

Not enough peers in active/passive view for requested hops.

Solutions:
- Reduce number of hops: `mycelium:circuit_create(Target, #{hops => 1})`
- Wait for more peers to join the network
- Check `mycelium:active_view()` and `mycelium:passive_view()`

**`{circuit_failed, _, timeout}`**

Circuit did not establish within 30 seconds.

Solutions:
- Check network connectivity to target
- Verify target node is running and reachable
- Check relay nodes are healthy

**`{circuit_failed, _, {transport_down, _}}`**

Network connection to first hop failed.

Solutions:
- Check firewall allows the dist QUIC port (UDP)
- Verify peer is still in active view
- Check for network partitions

### Data Transmission Issues

**`{error, circuit_not_ready}`**

Attempted to send before circuit fully established.

Solution: Wait for `{circuit_ready, CircuitId}` message before sending.

**`{circuit_closed, _, decrypt_failed}`**

Data decryption failed, indicating corrupted or tampered data.

This should be rare. Check for:
- Memory corruption
- Man-in-the-middle attacks (if encryption was compromised)
- Bugs in custom relay implementations

### Resource Issues

**Too many relay circuits**

Check `mycelium_circuit_relay:count()`. If near `circuit_relay_max`:
- Increase limit in configuration
- Reduce circuit TTL to free resources faster
- Monitor which nodes are creating excessive circuits

### Monitoring Circuit Health

```erlang
%% Check circuit status
{ok, Info} = mycelium:circuit_info(CircuitId).

%% List all circuits
Circuits = mycelium:list_circuits().

%% Check relay load
RelayCount = mycelium_circuit_relay:count().

%% Get metrics
Metrics = mycelium_circuit_metrics:get_metrics().

%% Check NAT status
NatType = mycelium_nat:get_nat_type().
{ok, ExtAddr, ExtPort} = mycelium_nat:get_external_address().
```

## See Also

- [NAT Traversal](nat-traversal.md) - NAT discovery, hole punching, and relay fallback
- [Authentication](authentication.md) - Ed25519 peer authentication
- [Getting Started](getting-started.md) - Initial setup and configuration
- [Internals](internals.md) - HyParView membership protocol
