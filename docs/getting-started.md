# Getting Started with Mycelium

This guide walks you through setting up Mycelium in your Erlang project and running your first distributed cluster.

## Prerequisites

- Erlang/OTP 26 or later
- rebar3 build tool

## Adding Mycelium to Your Project

Add mycelium to your `rebar.config`:

```erlang
{deps, [
    {mycelium, "0.1.0"}
]}.
```

Fetch the dependency:

```bash
rebar3 get-deps
rebar3 compile
```

## Configuration

Create or update your `config/sys.config`:

```erlang
[
    {mycelium, [
        %% HyParView membership parameters
        {active_size, 5},         %% Connected peers (log n recommended)
        {passive_size, 30},       %% Known peers cache
        {shuffle_period, 10000},  %% View exchange interval (ms)

        %% Network
        {listen_port, 9100},      %% Distribution port (0 = auto)
        {contact_nodes, []},      %% Bootstrap nodes

        %% Authentication (optional)
        {auth_enabled, true},
        {auth_trust_mode, tofu}   %% tofu | strict
    ]}
].
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `active_size` | 5 | Maximum connected peers. Set to approximately log(n) where n is expected cluster size |
| `passive_size` | 30 | Maximum known peers in passive view |
| `arwl` | 6 | Active Random Walk Length for join propagation |
| `prwl` | 3 | Passive Random Walk Length |
| `shuffle_length` | 8 | Peers exchanged per shuffle round |
| `shuffle_period` | 10000 | Milliseconds between shuffle rounds |
| `listen_port` | 0 | Port for incoming connections (0 = OS assigned) |
| `contact_nodes` | [] | List of bootstrap nodes to join on startup |
| `auth_enabled` | true | Enable Ed25519 peer authentication |
| `auth_trust_mode` | tofu | `tofu` (trust on first use) or `strict` (pre-shared keys only) |

### Circuit Routing Options

| Option | Default | Description |
|--------|---------|-------------|
| `circuit_default_hops` | 2 | Default number of intermediate relay hops |
| `circuit_default_ttl` | 3600000 | Default circuit lifetime in ms (1 hour) |
| `circuit_relay_max` | 500 | Maximum circuits this node will relay |
| `circuit_idle_timeout` | 300000 | Idle relay cleanup interval in ms (5 min) |
| `circuit_listen_port` | 0 | Port for circuit transport (0 = OS assigned) |
| `circuit_pool_size` | 3 | Connection pool size per destination |

## Starting Your First Node

### Option 1: Interactive Shell

```bash
rebar3 shell --config config/sys.config --sname node1
```

```erlang
%% Mycelium starts automatically with the application
%% Verify it's running
mycelium:active_view().
%% Returns: [] (no peers yet)
```

### Option 2: Release

Add mycelium to your release in `rebar.config`:

```erlang
{relx, [
    {release, {myapp, "1.0.0"}, [
        myapp,
        mycelium
    ]},
    {sys_config, "config/sys.config"}
]}.
```

## Joining a Cluster

Start two nodes and have them find each other:

**Terminal 1 - First Node (Seed)**
```bash
rebar3 shell --sname seed --config config/sys.config
```

**Terminal 2 - Second Node**
```bash
rebar3 shell --sname node1 --config config/sys.config
```

```erlang
%% Join the seed node
mycelium:join('seed@localhost').
%% Returns: ok

%% Verify connection
mycelium:active_view().
%% Returns: ['seed@localhost']
```

### Using Contact Nodes

For automatic cluster join on startup, configure contact nodes:

```erlang
{mycelium, [
    {contact_nodes, ['seed@192.168.1.10', 'seed@192.168.1.11']}
]}
```

Mycelium will attempt to join via these nodes when the application starts.

## Verifying Connectivity

### Check Membership

```erlang
%% Connected peers (active view)
mycelium:active_view().
%% ['node2@host', 'node3@host']

%% Known peers (passive view)
mycelium:passive_view().
%% ['node4@host', 'node5@host', ...]
```

### Subscribe to Events

```erlang
%% Subscribe the shell process
mycelium:subscribe().

%% When nodes join/leave, you'll receive:
%% {hyparview_event, {joined, 'newnode@host'}}
%% {hyparview_event, {left, 'oldnode@host'}}

%% Unsubscribe when done
mycelium:unsubscribe(self()).
```

### Register and Find Services

```erlang
%% Register a service on this node
mycelium:register_service(my_service).

%% On another node, find it
{ok, Pid} = mycelium:whereis_service(my_service).

%% List all services in the cluster
mycelium:list_services().
%% [my_service]
```

## Leaving the Cluster

```erlang
%% Graceful departure - notifies peers
mycelium:leave().
```

## Troubleshooting

### Node Won't Join

1. Verify the contact node is reachable: `net_adm:ping('contact@host')`
2. Check firewall allows the listen port
3. Ensure Erlang cookies match if using distributed Erlang

### No Services Found

1. Verify the service is registered: `mycelium:list_services()`
2. Check active view has peers: `mycelium:active_view()`
3. Allow time for CRDT replication (typically < 1 second)

### Authentication Failures

Mycelium uses Ed25519 authentication by default with two trust modes:

- **TOFU mode** (default): Keys are trusted on first contact
- **Strict mode**: Peer keys must be pre-registered

Common issues:

1. **Key mismatch error**: A node's key changed (regenerated or MITM attack)
   ```erlang
   %% Check what key is stored
   %% Keys are identified by fingerprint, not node name
   %% Get the fingerprint of the problem key
   Fp = mycelium_dist_keys:fingerprint(ProblemPubKey).
   mycelium_dist_keys:lookup_key(Fp).

   %% Delete and re-trust if key was legitimately rotated
   mycelium_dist_keys:delete_key(Fp).
   ```

2. **Untrusted key in strict mode**: Node not pre-registered
   ```erlang
   %% Register the peer's public key (identity is based on key, not node name)
   PeerPubKey = <<...>>.  %% Get from peer
   mycelium_dist_keys:store_key(PeerPubKey).
   ```

3. **View trusted keys**:
   ```erlang
   %% Keys are identified by fingerprint
   mycelium_dist_keys:list_trusted().
   %% Returns list of #peer_key{fingerprint, public_key, ...}
   ```

See [Authentication](authentication.md) for details on key provisioning and strict mode setup.

## Next Steps

- [Tutorial: Building P2P Applications](tutorial.md) - Build a distributed chat system
- [Circuit Routing](circuits.md) - Multi-hop encrypted communication
- [Authentication](authentication.md) - Key management and trust modes
- [Internals](internals.md) - Understand the protocols and architecture
