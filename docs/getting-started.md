# Getting Started with Mycelium

This guide walks you through setting up Mycelium in your Erlang project and running your first distributed cluster.

## Prerequisites

- Erlang/OTP 27 or later
- rebar3 build tool
- `-proto_dist quic -epmd_module quic_epmd -start_epmd false` in your
  boot args. Mycelium runs on upstream `quic_dist` (EPMD-less) and
  plugs in via the `auth_callback` and `discovery_module` options.
  The default `config/sys.config` wires those.

## First-boot setup: TLS cert and Ed25519 keypair

Each node carries two pieces of identity material on disk.

**1. QUIC TLS certificate (`data/quic/node.crt`, `node.key`).**
The kernel app starts distribution *before* mycelium's application
code runs, so the cert must already exist when the BEAM boots —
`quic_dist:listen/2` fails with `{credentials, no_credentials}`
otherwise. Generate a self-signed pair with `openssl`:

```bash
mkdir -p data/quic
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout data/quic/node.key -out data/quic/node.crt \
    -subj '/CN=mycelium'
```

Or, if you'd rather not depend on `openssl`, use the bundled helper
once mycelium is compiled into `_build/`:

```bash
erl -noshell -pa _build/default/lib/*/ebin \
    -eval 'application:load(mycelium), mycelium_quic_cert:ensure_cert("data/quic"), halt().'
```

`ensure_cert/1` is idempotent — re-running it is a no-op when the
files already exist.

**2. Ed25519 identity keypair (`data/keys/`).** Used by the dist auth
callback for peer authentication. The keypair is **generated lazily**
on first `mycelium_app:start/2` (via
`mycelium_dist_auth:ensure_keypair/0`); no manual step is required.
The public key fingerprint is logged on startup.

To inspect or rotate the keypair manually after the application is
running:

```erlang
%% Read the current keypair.
{ok, PubKey} = mycelium_dist_auth:get_public_key().
mycelium_dist_keys:fingerprint(PubKey).
%% => 32-byte SHA-256 binary

%% Force-regenerate (deletes existing files first).
file:delete("data/keys/node.pub"),
file:delete("data/keys/node.priv"),
ok = mycelium_dist_auth:ensure_keypair().
```

For pre-shared (`strict`) trust where every peer key is provisioned
ahead of time, see [Authentication](authentication.md).

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

## Starting Your First Node

### Option 1: Interactive Shell

Make sure `data/quic/node.{crt,key}` exist (see "First-boot setup"
above), then:

```bash
ERL_AFLAGS="-proto_dist quic" \
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
ERL_AFLAGS="-proto_dist quic" \
rebar3 shell --sname seed --config config/sys.config
```

**Terminal 2 - Second Node**
```bash
ERL_AFLAGS="-proto_dist quic" \
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
   %% Inspect the fingerprint (SHA-256 of the public key) for logs.
   Fp = mycelium_dist_keys:fingerprint(ProblemPubKey).

   %% Lookup, delete, and re-trust are keyed by node atom.
   {ok, StoredPubKey} = mycelium_dist_keys:lookup_key('peer@host').
   mycelium_dist_keys:delete_key('peer@host').
   ```

2. **Untrusted key in strict mode**: Node not pre-registered
   ```erlang
   %% Register the peer's public key under its node atom.
   PeerPubKey = <<...>>.  %% Get from peer
   mycelium_dist_keys:store_key('peer@host', PeerPubKey).
   ```

3. **View trusted keys**:
   ```erlang
   mycelium_dist_keys:list_trusted().
   %% Returns list of #peer_key{fingerprint, public_key, ...}
   ```

See [Authentication](authentication.md) for details on key provisioning and strict mode setup.

## Running the test suite

`rebar3 ct` runs the local CT suites (no docker needed). The
multi-node integration suites are docker-only and live behind
the wrappers in `docker/scripts/`. See [Testing](testing.md)
for the full command list.

## Next Steps

- [Tutorial: Building P2P Applications](tutorial.md) - Build a distributed chat system
- [Authentication](authentication.md) - Key management and trust modes
- [External Relay](external-relay.md) - Wiring an out-of-tree tunnel/relay adapter
- [Testing](testing.md) - Local and docker test commands
- [Internals](internals.md) - Understand the protocols and architecture
