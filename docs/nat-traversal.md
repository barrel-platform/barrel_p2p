# NAT Traversal

NAT traversal enables Mycelium nodes behind Network Address Translation (NAT) to establish direct connections with other peers. This is essential for peer-to-peer connectivity when nodes are not publicly reachable.

## Overview

Most nodes in real-world deployments sit behind NAT gateways (home routers, corporate firewalls, cloud NAT). Mycelium handles this through:

- **NAT type detection**: Uses STUN (RFC 5780) to determine NAT behavior
- **Candidate discovery**: Identifies reachable addresses (local, STUN reflexive, relay)
- **Hole punching**: Coordinates UDP hole punching for compatible NAT types
- **Automatic fallback**: Uses relay routing when direct connection isn't possible

### NAT Types

Mycelium classifies NAT behavior according to RFC 5780:

| NAT Type | Description | Hole Punch Compatible |
|----------|-------------|----------------------|
| `public` | No NAT, directly reachable | Yes (always) |
| `full_cone` | Any external host can reach via mapped address | Yes |
| `restricted_cone` | External host must receive packet first (IP restricted) | Yes |
| `port_restricted` | External host must receive packet first (IP+port restricted) | Yes |
| `symmetric` | Different mapping per destination | No (relay only) |
| `unknown` | Could not determine | No (relay only) |

### Hole Punch Viability Matrix

| Local \ Remote | public | full_cone | restricted | port_restricted | symmetric |
|----------------|--------|-----------|------------|-----------------|-----------|
| public | Yes | Yes | Yes | Yes | Yes |
| full_cone | Yes | Yes | Yes | Yes | No |
| restricted | Yes | Yes | Yes | Yes | No |
| port_restricted | Yes | Yes | Yes | Yes | No |
| symmetric | Yes | No | No | No | No |

When hole punching isn't viable, Mycelium automatically falls back to relay routing through the HyParView overlay network.

## Architecture

### Components

```
+------------------+     +-------------------+     +------------------+
|   mycelium_nat   |---->| mycelium_nat_cache|<----|  mycelium_hole   |
|   (Discovery)    |     |   (NAT Info)      |     |     _punch       |
+------------------+     +-------------------+     +------------------+
        |                        ^                        |
        v                        |                        v
   +---------+              +---------+             +-----------+
   |  estun  |              |  Hello  |             | UDP Socket|
   |  (STUN) |              | Protocol|             | Signaling |
   +---------+              +---------+             +-----------+
```

- **mycelium_nat**: NAT discovery facade, handles STUN queries and UPnP/NAT-PMP
- **mycelium_nat_cache**: Caches local and peer NAT information with TTL expiration
- **mycelium_hole_punch**: Coordinates UDP hole punching between peers

### Discovery Flow

1. On startup, `mycelium_nat` queries STUN servers to discover external address
2. NAT type is determined by analyzing mapping/filtering behavior
3. UPnP/NAT-PMP is attempted for port mapping (if enabled)
4. Connection candidates are built (host + server-reflexive)
5. Results are cached in `mycelium_nat_cache`
6. Periodic rediscovery (default: every 30 minutes) handles network changes

### Connection Candidates

Candidates represent possible ways to reach a node:

| Type | Priority | Description |
|------|----------|-------------|
| `host` | 200 | Local network address (fastest if reachable) |
| `srflx` | 100 | STUN server-reflexive (external NAT address) |
| `relay` | 50 | TURN relay or overlay relay (always works) |

Connection attempts try candidates in priority order, falling back to lower priority options.

## Configuration

### NAT Discovery

```erlang
%% In sys.config or application:set_env
[
  {mycelium, [
    %% Enable/disable NAT traversal (default: true)
    {nat_enabled, true},

    %% STUN servers for NAT discovery
    {stun_servers, [
      {"stun.l.google.com", 19302},
      {"stun1.l.google.com", 19302}
    ]},

    %% NAT rediscovery interval in ms (default: 30 minutes)
    {nat_discovery_interval, 1800000},

    %% Enable UPnP/NAT-PMP port mapping (default: true)
    {upnp_enabled, true},

    %% UPnP mapping lifetime in seconds (default: 2 hours)
    {upnp_mapping_lifetime, 7200}
  ]}
].
```

### NAT Cache

```erlang
[
  {mycelium, [
    %% Local NAT info cache TTL in ms (default: 30 minutes)
    {nat_local_cache_ttl, 1800000},

    %% Peer NAT info cache TTL in ms (default: 1 hour)
    {nat_cache_ttl, 3600000}
  ]}
].
```

### Hole Punching

```erlang
[
  {mycelium, [
    %% Enable/disable hole punching (default: true)
    {hole_punch_enabled, true},

    %% Hole punch timeout in ms (default: 10 seconds)
    {hole_punch_timeout, 10000},

    %% Number of punch retries (default: 3)
    {hole_punch_retries, 3}
  ]}
].
```

## API Reference

### mycelium_nat

#### get_nat_type/0

Get the detected NAT type for this node.

```erlang
-spec get_nat_type() -> nat_type().

%% Example
port_restricted = mycelium_nat:get_nat_type().
```

#### get_external_address/0

Get the external (STUN-discovered) address.

```erlang
-spec get_external_address() -> {ok, Address, Port} | {error, Reason}.

%% Example
{ok, {203,0,113,50}, 54321} = mycelium_nat:get_external_address().
```

#### get_candidates/0

Get all connection candidates for this node.

```erlang
-spec get_candidates() -> [#candidate{}].

%% Example
[#candidate{type = host, address = {192,168,1,100}, port = 4370},
 #candidate{type = srflx, address = {203,0,113,50}, port = 54321}] =
    mycelium_nat:get_candidates().
```

#### add_port_mapping/2

Request a UPnP/NAT-PMP port mapping.

```erlang
-spec add_port_mapping(Port, Protocol) -> {ok, ExternalPort} | {error, Reason}
    when Port :: inet:port_number(),
         Protocol :: tcp | udp.

%% Example
{ok, 4370} = mycelium_nat:add_port_mapping(4370, tcp).
```

#### refresh/0

Force NAT rediscovery.

```erlang
-spec refresh() -> ok.

%% Example - trigger after network change
mycelium_nat:refresh().
```

### mycelium_nat_cache

#### get_local_nat/0

Get cached local NAT information.

```erlang
-spec get_local_nat() -> {ok, #nat_info{}} | {error, not_discovered}.
```

#### get_peer_nat/1

Get cached NAT information for a peer.

```erlang
-spec get_peer_nat(Node) -> {ok, #nat_info{}} | {error, not_found | expired}.

%% Example
{ok, #nat_info{nat_type = full_cone}} = mycelium_nat_cache:get_peer_nat('peer@host').
```

#### set_peer_nat/2

Cache NAT information for a peer (called automatically on hello exchange).

```erlang
-spec set_peer_nat(Node, NatInfo) -> ok.
```

#### list_peers/0

List all cached peer NAT information.

```erlang
-spec list_peers() -> [{Node, #nat_info{}}].
```

### mycelium_hole_punch

#### is_viable/2

Check if hole punching is viable between two NAT types.

```erlang
-spec is_viable(LocalNat, RemoteNat) -> boolean().

%% Examples
true = mycelium_hole_punch:is_viable(port_restricted, full_cone).
false = mycelium_hole_punch:is_viable(symmetric, port_restricted).
```

#### punch/2

Attempt hole punch to a peer (synchronous).

```erlang
-spec punch(Peer, Opts) -> {ok, Socket} | {error, Reason}.

%% Example
case mycelium_hole_punch:punch('peer@host', #{timeout => 5000}) of
    {ok, Socket} ->
        %% Direct UDP connection established
        gen_udp:send(Socket, ...);
    {error, incompatible_nat_types} ->
        %% Fall back to relay
        use_relay(Peer)
end.
```

#### punch_async/2

Attempt hole punch asynchronously.

```erlang
-spec punch_async(Peer, Opts) -> {ok, SessionId} | {error, Reason}.

%% Start async punch
{ok, SessionId} = mycelium_hole_punch:punch_async('peer@host', #{}),

%% Result delivered as message
receive
    {hole_punch, SessionId, {ok, Socket}} ->
        io:format("Punch successful!~n");
    {hole_punch, SessionId, {error, Reason}} ->
        io:format("Punch failed: ~p~n", [Reason])
end.
```

## Hello Protocol Integration

NAT information is exchanged during the HyParView hello protocol:

1. When connecting to a peer, local NAT info is included in the hello message
2. Peer's NAT info is extracted and cached in `mycelium_nat_cache`
3. Cached info is used to determine connection strategy for future communications

### Hello Message V2 Format

```
+--------+------------+---------+----------+------------+
| Version| Sender Len | Sender  | NAT Type | Candidates |
| (1B)   | (2B)       | (var)   | (1B)     | (var)      |
+--------+------------+---------+----------+------------+
```

The protocol maintains backwards compatibility with V1 (no NAT info).

## Connection Strategy

When establishing a connection to a peer:

1. **Check viability**: Query `is_viable/2` with local and peer NAT types
2. **If viable**: Attempt hole punch using peer's candidates
3. **If not viable or punch fails**: Use relay routing through overlay
4. **Same-NAT optimization**: If external IPs match, prefer host candidates (local network)

### Same-NAT Optimization

When two nodes share the same external IP (behind the same NAT gateway), they can communicate directly on the local network:

```erlang
%% Both nodes have same external IP
PeerInfo = mycelium_nat_cache:get_peer_nat(Peer),
LocalInfo = mycelium_nat_cache:get_local_nat(),

case PeerInfo#nat_info.external_addr =:= LocalInfo#nat_info.external_addr of
    true ->
        %% Same NAT - use host candidate (local network)
        connect_via_host_candidate(PeerInfo#nat_info.candidates);
    false ->
        %% Different NAT - use srflx candidate (hole punch)
        attempt_hole_punch(Peer)
end.
```

## Troubleshooting

### NAT Discovery Fails

If NAT discovery fails consistently:

1. Check STUN server connectivity: `nc -u stun.l.google.com 19302`
2. Verify firewall allows outbound UDP on port 3478/19302
3. Try alternative STUN servers
4. Check logs for estun errors

### Hole Punch Fails

If hole punching fails between compatible NATs:

1. Verify both peers have valid candidates: `mycelium_nat:get_candidates()`
2. Check NAT types: symmetric NAT cannot hole punch
3. Increase timeout: `{hole_punch_timeout, 15000}`
4. Check UDP is not blocked by firewall
5. Some carrier-grade NATs (CGNAT) may block hole punching

### UPnP Not Working

If UPnP port mapping fails:

1. Verify router supports UPnP/NAT-PMP
2. Enable UPnP in router settings
3. Check only one UPnP client is requesting the port
4. Some ISP-provided routers disable UPnP

## Testing

Run the NAT traversal test suite:

```bash
# Run all NAT tests
rebar3 ct --suite=mycelium_nat_SUITE,mycelium_hole_punch_SUITE,mycelium_nat_exchange_SUITE,mycelium_nat_integration_SUITE

# Run specific test group
rebar3 ct --suite=mycelium_nat_SUITE --group=nat_cache_tests

# Run with verbose output
rebar3 ct --suite=mycelium_nat_SUITE --verbose
```

### Test Coverage

| Suite | Tests | Coverage |
|-------|-------|----------|
| mycelium_nat_SUITE | 17 | Cache ops, discovery, viability, candidates |
| mycelium_hole_punch_SUITE | 7 | Sessions, signaling, viability matrix |
| mycelium_nat_exchange_SUITE | 7 | Hello V2 encoding, NAT exchange |
| mycelium_nat_integration_SUITE | 5 | E2E simulated NAT scenarios |
