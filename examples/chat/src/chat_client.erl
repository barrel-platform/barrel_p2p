-module(chat_client).

-export([start/0, stop/1]).
-export([create_room/1, join/2, leave/2, send/2, rooms/0]).
-export([demo/0]).

%% Start a chat client that listens for messages
start() ->
    Pid = spawn_link(fun() ->
        barrel_p2p:subscribe_services(),
        listener_loop()
    end),
    {ok, Pid}.

stop(Pid) ->
    Pid ! stop,
    ok.

%% Create a new chat room on this node
create_room(Name) ->
    chat_room_sup:create_room(Name).

%% Join a room with a listener process
join(Room, ListenerPid) ->
    chat_server:join_room(Room, ListenerPid).

%% Leave a room
leave(Room, _ListenerPid) ->
    chat_server:leave_room(Room).

%% Send a message to a room
send(Room, Message) ->
    chat_server:send(Room, Message).

%% List all available rooms
rooms() ->
    chat_server:list_rooms().

%% Demo function to test the chat
demo() ->
    io:format("=== Chat Demo ===~n"),
    io:format("Node: ~p~n", [node()]),

    %% Start client
    {ok, Client} = start(),
    io:format("Started client: ~p~n", [Client]),

    %% Create a room
    {ok, _RoomPid} = create_room(demo_room),
    io:format("Created room: demo_room~n"),

    %% Wait for service to propagate
    timer:sleep(500),

    %% Join the room
    ok = join(demo_room, Client),
    io:format("Joined demo_room~n"),

    %% Send a message
    ok = send(demo_room, "Hello from " ++ atom_to_list(node())),
    io:format("Sent message~n"),

    %% List rooms
    Rooms = rooms(),
    io:format("Available rooms: ~p~n", [Rooms]),

    io:format("=== Demo complete ===~n"),
    {ok, Client}.

%% Internal listener loop
listener_loop() ->
    receive
        {chat_message, Room, FromNode, Text, Timestamp} ->
            {{Y,M,D},{H,Mi,S}} = calendar:now_to_datetime(Timestamp),
            io:format("[~p] ~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B <~p> ~s~n",
                      [Room, Y, M, D, H, Mi, S, FromNode, Text]),
            listener_loop();
        {barrel_p2p_service_event, {service_registered, {chat_room, Room}, Node}} ->
            io:format("*** Room '~p' available on ~p~n", [Room, Node]),
            listener_loop();
        {barrel_p2p_service_event, {service_unregistered, {chat_room, Room}, Node}} ->
            io:format("*** Room '~p' closed on ~p~n", [Room, Node]),
            listener_loop();
        {barrel_p2p_service_event, _Other} ->
            listener_loop();
        stop ->
            ok;
        Other ->
            io:format("Unknown message: ~p~n", [Other]),
            listener_loop()
    end.
