# Building P2P Applications with Mycelium

This tutorial guides you through building distributed peer-to-peer applications using Mycelium. By the end, you'll have built a working distributed chat system.

## Introduction to P2P in Erlang

Traditional Erlang distribution creates a fully connected mesh - every node connects to every other node. This works well for small clusters but becomes problematic at scale:

- N nodes require N*(N-1)/2 connections
- Node joins/leaves cause O(N) connection changes
- Network partitions affect many connections

Mycelium solves this with partial membership. Each node maintains only log(N) connections while still being able to reach any node through overlay routing. For sensitive communication, circuit routing provides end-to-end encrypted channels through multiple relay hops.

## Understanding Cluster Membership

Mycelium uses the HyParView protocol to manage membership. Each node maintains two views:

**Active View**: Currently connected peers (small, typically 5 nodes)
**Passive View**: Known but unconnected peers (larger, typically 30 nodes)

```erlang
%% Check your views
ActivePeers = mycelium:active_view().
PassivePeers = mycelium:passive_view().
```

The active view is kept small to limit connection overhead while the passive view provides backup peers if active connections fail.

### Joining and Leaving

```erlang
%% Join through a known node
mycelium:join('seed@example.com').

%% The join propagates through the network via "forward join"
%% After joining, you'll have active connections

%% Leave gracefully (notifies peers)
mycelium:leave().
```

When you join, the protocol ensures you get integrated into the overlay without disrupting existing connections.

## Registering and Discovering Services

Services are named processes that can be found across the cluster.

### Registering Services

```erlang
%% Simple registration
mycelium:register_service(user_service).

%% With metadata
mycelium:register_service(cache_service, #{
    shard => 1,
    capacity => 10000
}).
```

Registrations are replicated across the cluster using a CRDT (Conflict-free Replicated Data Type), ensuring eventual consistency without coordination.

### Finding Services

```erlang
%% Find all instances
{ok, Entries} = mycelium:lookup(user_service).
%% Entries = [{user_service, Pid, Node, Meta}, ...]

%% Find any instance (prefers local)
{ok, Pid} = mycelium:whereis_service(user_service).

%% Find local instance only
{ok, LocalPid} = mycelium:lookup_local(user_service).
```

`whereis_service/1` is the recommended way to find services. It checks:
1. Local registry first
2. Remote registry cache
3. Overlay routing if not found

## Subscribing to Events

Stay informed about cluster changes:

### Membership Events

```erlang
mycelium:subscribe().

receive
    {hyparview_event, {joined, Node}} ->
        io:format("~p joined the cluster~n", [Node]);
    {hyparview_event, {left, Node}} ->
        io:format("~p left the cluster~n", [Node])
end.
```

### Service Events

```erlang
mycelium:subscribe_services().

receive
    {mycelium_service_event, {service_registered, Name, Node}} ->
        io:format("Service ~p registered on ~p~n", [Name, Node]);
    {mycelium_service_event, {service_unregistered, Name, Node}} ->
        io:format("Service ~p unregistered from ~p~n", [Name, Node]);
    {mycelium_service_event, {service_down, Name, Node, Reason}} ->
        io:format("Service ~p on ~p went down: ~p~n", [Name, Node, Reason])
end.
```

## Secure Communication with Circuits

For sensitive data, circuit routing creates encrypted multi-hop channels where intermediate nodes cannot read the traffic.

### Creating Circuits

```erlang
%% Create a circuit to target node (default: 2 relay hops)
{ok, CircuitId} = mycelium:circuit_create('target@host').

%% Wait for circuit to establish
receive
    {circuit_ready, CircuitId} ->
        io:format("Circuit ready~n");
    {circuit_failed, CircuitId, Reason} ->
        io:format("Circuit failed: ~p~n", [Reason])
after 30000 ->
    io:format("Timeout~n")
end.
```

### Sending and Receiving Data

```erlang
%% Send encrypted data
ok = mycelium:circuit_send(CircuitId, <<"secret message">>).

%% Receive data (as initiator)
receive
    {circuit_data, CircuitId, Data} ->
        io:format("Received: ~p~n", [Data])
end.

%% Close when done
mycelium:circuit_close(CircuitId).
```

### Accepting Incoming Circuits

To receive circuit connections, register as a listener:

```erlang
%% Register as circuit listener
ok = mycelium:circuit_listen().

%% Handle incoming circuits
loop() ->
    receive
        {circuit_ready, CircuitId} ->
            io:format("New circuit: ~p~n", [CircuitId]),
            loop();
        {circuit_data, CircuitId, Data} ->
            %% Echo back
            mycelium:circuit_send(CircuitId, Data),
            loop();
        {circuit_closed, CircuitId, Reason} ->
            io:format("Circuit closed: ~p~n", [Reason]),
            loop()
    end.
```

### When to Use Circuits

| Scenario | Use Circuits? |
|----------|---------------|
| Private messages between users | Yes |
| Sensitive configuration data | Yes |
| High-volume broadcast | No (use Plumtree) |
| Service discovery | No (use registry) |
| Real-time gaming | No (latency overhead) |

See [Circuit Routing](circuits.md) for the full API reference and advanced patterns.

## Building a Distributed Chat

Let's build a complete distributed chat system to demonstrate these concepts. A full working example is available in `examples/chat/`.

### Running the Example

The quickest way to try the chat:

```bash
cd examples/chat

# Terminal 1: Start seed node
./scripts/run-demo.sh seed

# Terminal 2: Join as node1
./scripts/run-demo.sh node 1

# Terminal 3: Join as node2
./scripts/run-demo.sh node 2
```

Or use Docker:

```bash
cd examples/chat
./scripts/run-demo.sh docker-up
docker compose exec seed /app/bin/chat remote_console
```

### Chat Server Module

The chat server (`examples/chat/src/chat_server.erl`):

```erlang
-module(chat_server).
-behaviour(gen_server).

%% API
-export([start_link/1, send/2, join_room/2, leave_room/1, list_rooms/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    room :: atom(),
    members = [] :: [{pid(), reference()}]
}).

%%% API

start_link(Room) ->
    gen_server:start_link(?MODULE, Room, []).

send(Room, Message) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:cast(Pid, {message, node(), Message});
        {error, not_found} ->
            {error, room_not_found}
    end.

join_room(Room, ListenerPid) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:call(Pid, {join, ListenerPid});
        {error, not_found} ->
            {error, room_not_found}
    end.

leave_room(Room) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:call(Pid, {leave, self()});
        {error, not_found} ->
            ok
    end.

list_rooms() ->
    Services = mycelium:list_services(),
    [Room || {chat_room, Room} <- Services].

%% Helper: find room, handling both local {ok, Pid} and remote {ok, Node, Pid}
find_room(Room) ->
    case mycelium:whereis_service({chat_room, Room}) of
        {ok, Pid} -> {ok, Pid};
        {ok, _Node, Pid} -> {ok, Pid};
        {error, not_found} -> {error, not_found}
    end.

%%% gen_server callbacks

init(Room) ->
    process_flag(trap_exit, true),
    ServiceName = {chat_room, Room},
    ok = mycelium:register_service(ServiceName, #{created => erlang:timestamp()}),
    {ok, #state{room = Room}}.

handle_call({join, Pid}, _From, State = #state{members = Members}) ->
    Ref = monitor(process, Pid),
    {reply, ok, State#state{members = [{Pid, Ref} | Members]}};

handle_call({leave, Pid}, _From, State = #state{members = Members}) ->
    case lists:keyfind(Pid, 1, Members) of
        {Pid, Ref} ->
            demonitor(Ref, [flush]),
            {reply, ok, State#state{members = lists:keydelete(Pid, 1, Members)}};
        false ->
            {reply, ok, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({message, FromNode, Text}, State = #state{room = Room, members = Members}) ->
    Message = {chat_message, Room, FromNode, Text, erlang:timestamp()},
    [Pid ! Message || {Pid, _Ref} <- Members],
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, _Reason}, State = #state{members = Members}) ->
    {noreply, State#state{members = lists:keydelete(Pid, 1, Members)}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{room = Room}) ->
    mycelium:unregister_service({chat_room, Room}),
    ok.
```

### Chat Room Supervisor

The room supervisor (`examples/chat/src/chat_room_sup.erl`):

```erlang
-module(chat_room_sup).
-behaviour(supervisor).

-export([start_link/0, create_room/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

create_room(Room) ->
    supervisor:start_child(?MODULE, [Room]).

init([]) ->
    ChildSpec = #{
        id => chat_server,
        start => {chat_server, start_link, []},
        restart => temporary,
        type => worker
    },
    {ok, {#{strategy => simple_one_for_one}, [ChildSpec]}}.
```

### Chat Client

The client helper (`examples/chat/src/chat_client.erl`):

```erlang
-module(chat_client).

-export([start/0, create_room/1, join/1, send/2, rooms/0]).

start() ->
    %% Subscribe to service events to discover new rooms
    mycelium:subscribe_services(),
    spawn_link(fun() -> listener_loop() end).

create_room(Name) ->
    chat_room_sup:create_room(Name).

join(Room) ->
    chat_server:join_room(Room, self()).

send(Room, Message) ->
    chat_server:send(Room, Message).

rooms() ->
    chat_server:list_rooms().

listener_loop() ->
    receive
        {chat_message, Room, _From, Text, _Time} ->
            io:format("[~p] ~s~n", [Room, Text]),
            listener_loop();
        {mycelium_service_event, {service_registered, {chat_room, Room}, Node}} ->
            io:format("New room '~p' available on ~p~n", [Room, Node]),
            listener_loop();
        _Other ->
            listener_loop()
    end.
```

### Running the Chat

#### Two-Node Test

**Terminal 1 - Seed node:**
```bash
cd examples/chat
./scripts/run-demo.sh seed
```

This starts the seed node and runs `chat_client:demo()` which creates a `demo_room`.

**Terminal 2 - Join as node1:**
```bash
./scripts/run-demo.sh node 1
```

This joins the cluster and automatically connects to `demo_room`.

**Expected output on node1:**
```
[NODE1] Joining seed...
[NODE1] Joined cluster
[NODE1] Active view: [seed@hostname]
[NODE1] Discovered rooms: [demo_room]
*** Room 'demo_room' available on seed@hostname
[NODE1] Joined demo_room
```

#### Three-Node Test

Testing with 3 nodes demonstrates the partial mesh topology - each node connects to a subset of peers.

**Terminal 1 - Seed node:**
```bash
cd examples/chat
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

In the node2 shell, try:
```erlang
%% Check cluster membership
mycelium:active_view().
%% Returns: [seed@hostname] or [node1@hostname] (partial mesh)

%% Discover rooms from any node in cluster
chat_server:list_rooms().
%% Returns: [demo_room]

%% Create a room on node2
chat_room_sup:create_room(node2_room).

%% All nodes see both rooms via CRDT replication
chat_server:list_rooms().
%% Returns: [demo_room, node2_room]

%% Send message to demo_room (hosted on seed)
chat_client:send(demo_room, "Hello from node2!").
```

**What happens:**
1. Node2 joins via seed (or node1)
2. Service registry replicates via Plumtree broadcast
3. `demo_room` on seed is discovered by node2
4. `node2_room` propagates to seed and node1
5. Messages route through the overlay to the room's host node

#### Manual Shell Testing

For more control, use `rebar3 shell` directly:

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
timer:sleep(500).  %% Wait for service replication
chat_client:join(demo_room, C).
chat_client:send(demo_room, "Hello from node1!").
```

**Terminal 3:**
```bash
rebar3 shell --sname node2 --setcookie chat
```
```erlang
mycelium:join('seed@hostname').
{ok, C} = chat_client:start().
chat_server:list_rooms().  %% See rooms from cluster
chat_room_sup:create_room(erlang_help).  %% Create new room
chat_client:join(erlang_help, C).
chat_client:send(erlang_help, "Anyone here?").
```

#### Docker Cluster (4 nodes)

```bash
cd examples/chat
./scripts/run-demo.sh docker-up
```

Attach to any node:
```bash
docker compose exec seed /app/bin/chat remote_console
```

```erlang
mycelium:active_view().
chat_server:list_rooms().
chat_room_sup:create_room(docker_room).
```

Stop cluster:
```bash
./scripts/run-demo.sh docker-down
```

## Best Practices

### Service Registration

1. **Register early, unregister on termination**
   ```erlang
   init(_) ->
       mycelium:register_service(my_service),
       {ok, #state{}}.

   terminate(_, _) ->
       mycelium:unregister_service(my_service).
   ```

2. **Use meaningful metadata**
   ```erlang
   mycelium:register_service(worker, #{
       capabilities => [image_processing, ocr],
       load => 0.5
   }).
   ```

3. **Handle service not found gracefully**
   ```erlang
   case mycelium:whereis_service(needed_service) of
       {ok, Pid} -> do_work(Pid);
       {error, not_found} -> queue_for_later()
   end.
   ```

### Membership Events

1. **Don't assume instant propagation** - Service registrations take time to replicate
2. **Use events for cache invalidation**, not as the source of truth
3. **Handle reconnection** - Nodes may rejoin after network issues

### Overlay Routing

1. **Prefer whereis_service over manual routing** - It handles caching and retries
2. **Use local services when possible** - `lookup_local/1` is faster
3. **Consider service placement** - Colocate related services on the same node

## Common Patterns

### Service Pool

Run multiple instances of a service and load balance:

```erlang
%% Find all workers and pick one
{ok, Entries} = mycelium:lookup(worker_service),
{_, Pid, _, Meta} = pick_least_loaded(Entries),
gen_server:call(Pid, work).

pick_least_loaded(Entries) ->
    lists:min([{maps:get(load, Meta, 0), E} || E = {_, _, _, Meta} <- Entries]).
```

### Service Migration

Move a service to another node:

```erlang
%% On new node
{ok, State} = rpc:call(OldNode, my_service, get_state, []),
my_service:start_with_state(State).
%% Registration automatically updates via CRDT
```

### Graceful Degradation

Handle partial cluster failures:

```erlang
try_service(Name, Request) ->
    case mycelium:whereis_service(Name, #{retries => 3}) of
        {ok, Pid} ->
            try gen_server:call(Pid, Request, 5000)
            catch exit:{timeout, _} -> {error, timeout}
            end;
        {error, not_found} ->
            {error, service_unavailable}
    end.
```

## Next Steps

- [Circuit Routing](circuits.md) - Multi-hop encrypted communication
- [Internals](internals.md) - Deep dive into protocols and architecture
- [Partisan Comparison](partisan-comparison.md) - Understand the differences
