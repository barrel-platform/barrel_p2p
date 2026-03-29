# Distributed Chat Example

A distributed chat application demonstrating Mycelium's P2P capabilities.

## Features

- Chat rooms discoverable across the cluster
- Automatic service registry replication
- Messages broadcast to all room members
- Rooms persist when creator leaves (if other members exist)

## Quick Start (Local)

### Setup

The example uses rebar3 checkouts to reference the local mycelium library:

```bash
cd examples/chat

# Create checkouts symlink (done automatically by run-demo.sh)
mkdir -p _checkouts
ln -sf ../../.. _checkouts/mycelium
```

### Build

```bash
rebar3 compile

# Link mycelium in _build for rebar3 shell (done automatically by run-demo.sh)
ln -sf ../../../_checkouts/mycelium/_build/default/lib/mycelium _build/default/lib/mycelium
```

### Two-Node Demo

**Terminal 1 - Seed node:**
```bash
./scripts/run-demo.sh seed
```

This starts the seed node and creates `demo_room` automatically.

**Terminal 2 - Join as node1:**
```bash
./scripts/run-demo.sh node 1
```

**Expected output on node1:**
```
[NODE1] Joining seed...
[NODE1] Joined cluster
[NODE1] Active view: [seed@hostname]
[NODE1] Discovered rooms: [demo_room]
*** Room 'demo_room' available on seed@hostname
[NODE1] Joined demo_room
```

### Three-Node Demo

Testing with 3 nodes shows the partial mesh topology and CRDT replication.

**Terminal 1 - Seed node:**
```bash
./scripts/run-demo.sh seed
```

**Terminal 2 - Node1:**
```bash
./scripts/run-demo.sh node 1
```

**Terminal 3 - Node2:**
```bash
./scripts/run-demo.sh node 2
```

In the node2 shell:
```erlang
%% Check cluster membership (partial mesh)
mycelium:active_view().
%% Returns: [seed@hostname] or [node1@hostname]

%% Rooms discovered via CRDT replication
chat_server:list_rooms().
%% Returns: [demo_room]

%% Create room on node2
chat_room_sup:create_room(node2_room).

%% All nodes see both rooms
chat_server:list_rooms().
%% Returns: [demo_room, node2_room]

%% Send to room on different node
chat_client:send(demo_room, "Hello from node2!").
```

**What happens:**
1. Node2 joins via seed
2. Service registry replicates via Plumtree broadcast
3. `demo_room` on seed is discovered by node2
4. `node2_room` propagates to seed and node1
5. Messages route through overlay to room's host

### Manual Shell Testing

For more control:

**Terminal 1:**
```bash
rebar3 shell --sname seed --setcookie chat
```
```erlang
chat_client:demo().
```

**Terminal 2:**
```bash
rebar3 shell --sname node1 --setcookie chat
```
```erlang
mycelium:join('seed@hostname').
{ok, C} = chat_client:start().
timer:sleep(500).
chat_client:join(demo_room, C).
chat_client:send(demo_room, "Hello!").
```

**Terminal 3:**
```bash
rebar3 shell --sname node2 --setcookie chat
```
```erlang
mycelium:join('seed@hostname').
{ok, C} = chat_client:start().
chat_server:list_rooms().
chat_room_sup:create_room(help_room).
```

## Docker Setup

### Start Cluster

```bash
./scripts/run-demo.sh docker-up
```

This starts 4 nodes: seed, node1, node2, node3.

### Attach to Node

```bash
docker compose exec seed /app/bin/chat remote_console
```

### Run Tests

```bash
./scripts/test-docker.sh
```

### View Logs

```bash
./scripts/run-demo.sh docker-logs
```

### Stop Cluster

```bash
./scripts/run-demo.sh docker-down
```

## Architecture

```
chat_sup (supervisor)
└── chat_room_sup (simple_one_for_one)
    └── chat_server (gen_server, per room)
        - Registers as {chat_room, Name} in mycelium
        - Maintains member list with monitors
        - Broadcasts messages to members
```

## API

### chat_client

| Function | Description |
|----------|-------------|
| `start()` | Start a listener process |
| `create_room(Name)` | Create a chat room |
| `join(Room, Pid)` | Join a room with listener |
| `leave(Room, Pid)` | Leave a room |
| `send(Room, Msg)` | Send message to room |
| `rooms()` | List available rooms |
| `demo()` | Run interactive demo |

### chat_server

| Function | Description |
|----------|-------------|
| `list_rooms()` | List all rooms in cluster |
| `get_members(Room)` | Get room member pids |

## Files

```
examples/chat/
├── src/
│   ├── chat.app.src       # Application resource file
│   ├── chat_app.erl       # Application behavior
│   ├── chat_sup.erl       # Top supervisor
│   ├── chat_room_sup.erl  # Room supervisor
│   ├── chat_server.erl    # Room gen_server
│   └── chat_client.erl    # Client helper module
├── config/
│   ├── sys.config         # Application config
│   └── vm.args            # VM arguments
├── scripts/
│   ├── run-demo.sh        # Demo runner
│   ├── test-local.sh      # Local test instructions
│   ├── test-docker.sh     # Docker test script
│   └── docker-entrypoint.sh
├── docker-compose.yml
├── Dockerfile
└── rebar.config
```
