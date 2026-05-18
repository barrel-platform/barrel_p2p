# Practice handbook

This handbook picks up where [getting-started.md](../overview/getting-started.md)
ends. It is written for Erlang developers who already know OTP and
want to build something real on top of Mycelium.

We will build a small distributed chat application. The point is not
the chat itself. The point is the practice:

- register a process as a cluster service;
- find that service from another node;
- send normal Erlang messages to the returned pid;
- subscribe to cluster and service events;
- keep local caches correct while the cluster moves;
- open tagged QUIC streams when `Pid ! Msg` is not the right shape.

The full source is under [`examples/chat`](../examples/chat/README.md).
Use this document as a handbook: copy the shapes, then adapt them to
your own supervisors and `gen_server` modules.

## The mental model

Mycelium does not ask you to stop writing Erlang. You still build OTP
trees. You still pass pids around. You still use `gen_server:call/2`,
monitors, links, and normal messages.

What changes is the cluster below your code.

In standard Erlang distribution, every node connects to every other
node. That works well for small, trusted clusters. It becomes
expensive when the cluster grows, and awkward when nodes appear,
disappear, or move between network paths.

Mycelium splits the problem in two:

- **Membership** is kept small. Each node keeps a bounded active view,
  usually five peers, used for gossip and topology maintenance.
- **Addressing** stays Erlang. If your code holds a pid on another
  node, OTP opens the dist channel on demand and the send works.
- **Names** are cluster-wide. The service registry is a CRDT, so
  services can be registered on any node and discovered from any
  other node.

Read this graph from node A. The green peers are the active view.
They are the maintenance topology, not the whole cluster.

![HyParView active view: node A keeps a small set of active gossip peers and a passive cache of known peers.](diagrams/active-view.png)

The practice model is simple: many small OTP processes, registered
under useful names, addressed by name, then handled as normal pids.
When the cluster grows, the per-node maintenance cost stays bounded.

## What we are building

A chat application that lets nodes host chat rooms and lets clients
join, send, and receive messages. The interesting properties:

- Any node can host any room. The location of a room is discovered
  by name through the service registry.
- A new node joining the cluster sees existing rooms automatically.
- A client subscribing to a room receives messages from any sender
  on any node, with no extra wiring.

We will not build a UI; the application is meant to be poked at
through the shell or a small CLI.

## The shape of a chat room

Each room is a process. The process is a `gen_server` that holds:

- The room's name.
- The set of clients currently subscribed, with monitor refs so we
  notice when one dies.

That is the entire state. Senders cast messages into the room; the
room iterates over its subscriber set and forwards each message.

In code:

```erlang
-module(chat_server).
-behaviour(gen_server).

-export([start_link/1]).
-export([send/2, join_room/2, leave_room/1, list_rooms/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    room :: atom(),
    members = [] :: [{pid(), reference()}]
}).
```

The room name is registered as a *tagged* service name:

```erlang
init(Room) ->
    process_flag(trap_exit, true),
    ServiceName = {chat_room, Room},
    case mycelium:register_service(ServiceName, #{created => erlang:timestamp()}) of
        ok          -> {ok, #state{room = Room}};
        {error, Why} -> {stop, Why}
    end.
```

A few things are worth pointing out.

**The tagged name.** We register `{chat_room, Room}` rather than
just `Room`. The tuple shape gives us a namespace for chat-room
services: every name that begins with `chat_room` is unambiguously
a chat room. When we want to list rooms, we filter on the tag (see
below). This is a common pattern; mycelium does not care about the
shape of the name as long as it is hashable.

**`process_flag(trap_exit, true)`.** Not strictly required by
mycelium, but it is what lets us run cleanup code in `terminate/2`.
A clean exit calls `unregister_service` so the room disappears from
the cluster's view without waiting for the registry's down-detector.

**The metadata map.** The second argument to `register_service/2` is
any map you like. The registry stores it alongside the pid of the
calling process and replicates it with the registration. We store a
creation timestamp here; in a richer application, you might store the
room's settings, a load metric, a capability list, or any small
annotation that lets callers pick between multiple instances.

## Sending and receiving messages

The room may live on the local node or on a remote node. The caller
does not need to know. It asks the registry for a pid, then uses the
pid as Erlang code normally would.

This is the important flow. The service lookup is a Mycelium concern.
The message send is an Erlang distribution concern.

![Service lookup returns a pid, then OTP opens a QUIC dist channel on demand and delivers the Erlang message.](diagrams/message-passing.png)

Senders look up the room and cast:

```erlang
send(Room, Message) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:cast(Pid, {message, node(), Message});
        {error, not_found} ->
            {error, room_not_found}
    end.

%% Helper that unwraps both local and remote whereis_service results.
find_room(Room) ->
    case mycelium:whereis_service({chat_room, Room}) of
        {ok, Pid}             -> {ok, Pid};
        {ok, _Node, Pid}      -> {ok, Pid};
        {error, not_found}    -> {error, not_found}
    end.
```

`whereis_service/1` may return either `{ok, Pid}` (local instance)
or `{ok, Node, Pid}` (remote instance reachable through Erlang
distribution). The helper above hides that distinction; from the
application's point of view, both are "a pid I can talk to".

The receiving side is the room's `handle_cast`:

```erlang
handle_cast({message, FromNode, Text}, State = #state{room = Room, members = Members}) ->
    Msg = {chat_message, Room, FromNode, Text, erlang:timestamp()},
    lists:foreach(fun({Pid, _Ref}) -> Pid ! Msg end, Members),
    {noreply, State};
```

We use a plain `Pid ! Msg` to deliver. Because the dist channel is
opened on demand, this works whether the subscriber lives on the
same node as the room or on a different one.

## Joining and leaving a room

Two simple `handle_call` clauses:

```erlang
handle_call({join, Pid}, _From, S = #state{members = M}) ->
    case lists:keyfind(Pid, 1, M) of
        false ->
            Ref = monitor(process, Pid),
            {reply, ok, S#state{members = [{Pid, Ref} | M]}};
        _ ->
            {reply, {error, already_joined}, S}
    end;

handle_call({leave, Pid}, _From, S = #state{members = M}) ->
    case lists:keyfind(Pid, 1, M) of
        {Pid, Ref} ->
            demonitor(Ref, [flush]),
            {reply, ok, S#state{members = lists:keydelete(Pid, 1, M)}};
        false ->
            {reply, ok, S}
    end;
```

The monitor is the only state of substance. When a subscriber dies
(because its node went away, or because it crashed), we receive a
`'DOWN'` message and clean up:

```erlang
handle_info({'DOWN', Ref, process, Pid, _Reason}, S = #state{members = M}) ->
    case lists:keyfind(Ref, 2, M) of
        {Pid, Ref} ->
            {noreply, S#state{members = lists:keydelete(Pid, 1, M)}};
        false ->
            {noreply, S}
    end;
```

This is one of the places where mycelium fades into the background:
the monitor is a standard Erlang feature, and it works across the
mycelium dist channel exactly as it does over the default TCP
carrier.

## Listing rooms

A new client should discover rooms without prior knowledge. We list
all registered services and keep only the ones with our tag:

```erlang
list_rooms() ->
    [Room || {chat_room, Room} <- mycelium:list_services()].
```

`list_services/0` returns the set of names registered in the
cluster, as it is currently known on this node. The result is
*eventually consistent*: a room registered on another node may not
appear here for a fraction of a second. For a chat use-case that is
fine; for a hard-real-time application you would either ask through
the originating node or layer a stronger consistency primitive on
top.

## Wiring the room supervisor

Rooms are spun up on demand. A `simple_one_for_one` supervisor lets
us create one when a user asks:

```erlang
-module(chat_room_sup).
-behaviour(supervisor).

-export([start_link/0, create_room/1, stop_room/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

create_room(Room) ->
    supervisor:start_child(?MODULE, [Room]).

stop_room(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 5,
                 period => 10},
    ChildSpec = #{id => chat_server,
                  start => {chat_server, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
```

The room is `restart => temporary`: if a room crashes, we do not
restart it. The clients monitoring it will see the registration
disappear via `mycelium:subscribe_services/0` (see the next
section).

## The chat client

The client side is small. It subscribes to service events, joins
rooms, and listens for chat messages:

```erlang
-module(chat_client).

-export([start/0, stop/1]).
-export([create_room/1, join/2, leave/2, send/2, rooms/0]).

start() ->
    Pid = spawn_link(fun() ->
        mycelium:subscribe_services(),
        listener_loop()
    end),
    {ok, Pid}.

stop(Pid) -> Pid ! stop, ok.

create_room(Name) -> chat_room_sup:create_room(Name).
join(Room, Pid)   -> chat_server:join_room(Room, Pid).
leave(Room, _Pid) -> chat_server:leave_room(Room).
send(Room, Text)  -> chat_server:send(Room, Text).
rooms()           -> chat_server:list_rooms().

listener_loop() ->
    receive
        {chat_message, Room, FromNode, Text, _Ts} ->
            io:format("[~p] <~p> ~s~n", [Room, FromNode, Text]),
            listener_loop();
        {mycelium_service_event, {service_registered, {chat_room, Room}, Node}} ->
            io:format("*** Room ~p available on ~p~n", [Room, Node]),
            listener_loop();
        {mycelium_service_event, {service_unregistered, {chat_room, Room}, Node}} ->
            io:format("*** Room ~p left ~p~n", [Room, Node]),
            listener_loop();
        stop ->
            ok;
        _Other ->
            listener_loop()
    end.
```

Three things to notice:

- The listener does not care which node hosts a room. The cluster
  reports the events; the listener formats them.
- The event payload is structured, not stringly typed. You can
  match on the tag, the name, the originating node, and the reason
  without parsing text.
- The pattern of "subscribe and loop" is the natural shape; in your
  own application you would typically run the listener inside a
  `gen_server` and route events to its `handle_info/2`.

## Running the example

The full sources live under `examples/chat/`. To try the
three-node walkthrough on one host:

```bash
cd examples/chat
./scripts/run-demo.sh seed                    # terminal 1
./scripts/run-demo.sh node 1                  # terminal 2
./scripts/run-demo.sh node 2                  # terminal 3
```

Each node generates its own TLS material and Ed25519 identity on
first boot. The script wires the local mycelium source into the
release via `_checkouts/`, so any change you make in the parent
tree is visible after a recompile.

To exercise the cluster:

```erlang
%% On node 2
chat_room_sup:create_room(general).
chat_client:join(general, self()).
chat_client:send(general, "hello, mycelium").
```

You will see the message arrive on the listener, and (on the other
nodes) a `*** Room general available on node2@host` event when the
room registration propagates.

A four-node docker compose stack is also available:

```bash
./scripts/run-demo.sh docker-up
docker compose exec seed /app/bin/chat remote_console
```

## Service patterns you will reach for

Three patterns recur in real applications. Each builds on the
primitives above.

### Pool of workers

When several nodes register the same service name, `lookup/1`
returns all of them. Picking one (for example, the least loaded) is
a tiny helper:

```erlang
-include_lib("mycelium/include/mycelium.hrl").

least_loaded(Name) ->
    {ok, Entries} = mycelium:lookup(Name),
    Sorted = lists:sort(
        fun(A, B) ->
            maps:get(load, A#service_entry.meta, 0)
            =<
            maps:get(load, B#service_entry.meta, 0)
        end,
        Entries
    ),
    hd(Sorted).
```

The metadata you set at registration time is what makes this work.
A worker that periodically calls `register_service/2` (with the
same name and updated metadata) effectively publishes a load
signal.

### Graceful degradation

Service lookups should not crash callers when the cluster is in
flux. The recommended shape:

```erlang
call_service(Name, Request) ->
    case mycelium:whereis_service(Name, #{retries => 3}) of
        {ok, Pid} ->
            try gen_server:call(Pid, Request, 5000)
            catch
                exit:{timeout, _}  -> {error, timeout};
                exit:{noproc, _}   -> {error, gone}
            end;
        {ok, _Node, Pid} ->
            try gen_server:call(Pid, Request, 5000)
            catch
                exit:{timeout, _}  -> {error, timeout};
                exit:{noproc, _}   -> {error, gone}
            end;
        {error, not_found} ->
            {error, unavailable}
    end.
```

The retries option to `whereis_service/2` performs a small,
exponentially-backed-off retry loop when the lookup fails initially;
this absorbs the small replication delay after a new registration.

### Subscribing as cache invalidation

If you cache a service pid yourself for performance, subscribe to
service events and invalidate the cache when the cached service
goes down:

```erlang
init(_) ->
    mycelium:subscribe_services(),
    {ok, #{cache => #{}}}.

handle_info({mycelium_service_event, {service_down, Name, _Node, _Reason}}, S) ->
    {noreply, S#{cache := maps:remove(Name, maps:get(cache, S))}};
handle_info(_, S) ->
    {noreply, S}.
```

This pattern lets the cache stay accurate without polling.

## When `register_service` is not enough

Sometimes you do not want named processes; you want a *stream* of
bytes between two nodes. Mycelium ships a tagged-stream multiplex
for exactly this case: any application can open a QUIC stream
between two cluster peers, attach a short binary tag, and hand the
stream to a handler process.

The full surface is in [internals.md](../reference/architecture.md). The minimal
shape:

```erlang
%% On the receiving side
mycelium_streams:register_acceptor(<<"chat:dump">>, self()).
%% receive {mstream, StreamRef, opened, FromNode} and then
%% native {quic_dist_stream, StreamRef, {data, _, _}} messages.

%% On the sending side
{ok, SR} = mycelium_streams:open(<<"chat:dump">>, 'node2@host').
quic_dist:send(SR, <<"transcript starts here\n">>).
quic_dist:close_stream(SR).
```

This is the right tool when you want to move a large blob between
two nodes (an avatar, a log dump, a snapshot) without going through
the gossip layer.

## Things worth knowing before deploying

A few short notes that will save you time later:

- **Register early; unregister on exit.** The registry uses
  monitors, so a crashed process is eventually cleaned up
  automatically, but a graceful `unregister_service` is faster and
  removes the entry without waiting for the monitor to fire.
- **Names are global, not unique.** Two nodes can register the same
  name; consumers see both. If you want exclusivity, layer it on
  top, for example by having only one node attempt the registration.
- **Replication has a small delay.** A service registered on node A
  is observable from node B "soon", typically in a fraction of a
  second. Code that registers and immediately looks up on a
  different node should expect to retry briefly. The
  `whereis_service/2` retry option does this for you.
- **Active view is not the cluster.** `mycelium:active_view/0`
  returns a small subset of peers; it is not the whole cluster.
  Use `erlang:nodes/0` to see every node you have an open dist
  channel with, or `list_services/0` for service-level visibility.

## Where to go from here

- [internals.md](../reference/architecture.md) for the protocols underneath:
  HyParView, Plumtree, OR-Map, the QUIC carrier.
- [authentication.md](../how-to/configure-authentication.md) for trust modes, the
  on-disk format, and key rotation.
- [observability.md](../how-to/observe-cluster.md) for the metrics catalog.
- [deployment.md](../how-to/run-in-production.md) when you are ready to put a
  cluster behind a load.
- [migration.md](../how-to/migrate-connections.md) for the QUIC connection-migration
  feature, which is useful when nodes change network paths at
  runtime.
