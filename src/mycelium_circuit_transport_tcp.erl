-module(mycelium_circuit_transport_tcp).
-behaviour(gen_server).
-behaviour(mycelium_circuit_transport).

%% TCP transport for circuit traffic - Simplified Design
%%
%% One connection per peer (no pool). Connection lifecycle:
%% - First circuit to peer -> establish connection
%% - Connection stays open while any circuit exists to that peer
%% - All circuits to peer closed -> close connection
%% - Connection breaks -> notify all circuits using it
%%
%% Wire protocol:
%%   <<FrameLen:32, CircuitIdLen:8, CircuitId/binary, MsgType:8, Payload/binary>>
%%
%% Control messages (IdLen=0):
%%   <<0:8, Type:8>> where Type = PING (7) or PONG (8)

-include("mycelium.hrl").

%% Behaviour callbacks
-export([
    start_link/1,
    connect/2,
    send/3,
    close/1,
    get_connection/1,
    release_connection/2
]).

%% API
-export([
    list_connections/0,
    get_listen_port/0,
    get_peer_port/1,
    register_circuit/3,
    unregister_circuit/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(CONN_TABLE, mycelium_circuit_connections).
-define(PORT_TABLE, mycelium_circuit_ports).

-record(state, {
    listener           :: port() | undefined,
    listen_port        :: inet:port_number(),
    acceptor_pid       :: pid() | undefined,
    connect_timeout    :: pos_integer(),
    heartbeat_interval :: pos_integer(),
    dead_interval      :: pos_integer(),
    auth_enabled       :: boolean()
}).

-record(conn, {
    socket      :: port(),
    node        :: node(),
    direction   :: inbound | outbound,
    circuits    :: sets:set({binary(), node()}),  %% {CircuitIdBin, Initiator} -> CircuitPid
    circuit_pids :: #{pid() => {binary(), node()}}, %% Reverse mapping for monitor cleanup
    created_at  :: integer(),
    last_pong   :: integer(),  %% erlang:monotonic_time(millisecond)
    receiver    :: pid(),
    ping_timer  :: reference() | undefined
}).

%%====================================================================
%% Behaviour Callbacks
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

-spec connect(node(), map()) -> {ok, mycelium_circuit_transport:conn_ref()} | {error, term()}.
connect(Node, Opts) ->
    gen_server:call(?SERVER, {connect, Node, Opts}, infinity).

-spec send(mycelium_circuit_transport:conn_ref(), #circuit_id{}, binary()) ->
    ok | {error, term()}.
send({tcp, Socket, _ConnPid}, CircuitId, Data) ->
    Frame = encode_frame(CircuitId, Data),
    gen_tcp:send(Socket, Frame).

-spec close(mycelium_circuit_transport:conn_ref()) -> ok.
close({tcp, Socket, _ConnPid}) ->
    gen_tcp:close(Socket),
    ok.

-spec get_connection(node()) -> {ok, mycelium_circuit_transport:conn_ref()} | {error, term()}.
get_connection(Node) ->
    gen_server:call(?SERVER, {get_connection, Node}, infinity).

-spec release_connection(node(), mycelium_circuit_transport:conn_ref()) -> ok.
release_connection(_Node, _ConnRef) ->
    %% No-op in simplified design - connections stay open until circuits close
    ok.

%%====================================================================
%% API
%%====================================================================

%% @doc List all active connections
-spec list_connections() -> [{node(), map()}].
list_connections() ->
    gen_server:call(?SERVER, list_connections).

%% @doc Get the listening port for circuit connections
-spec get_listen_port() -> inet:port_number().
get_listen_port() ->
    gen_server:call(?SERVER, get_listen_port).

%% @doc Get the circuit port for a peer node
-spec get_peer_port(node()) -> {ok, inet:port_number()} | {error, term()}.
get_peer_port(Node) ->
    case ets:lookup(?PORT_TABLE, Node) of
        [{_, Port}] -> {ok, Port};
        [] -> {error, not_found}
    end.

%% @doc Register a circuit on a connection
-spec register_circuit(node(), #circuit_id{}, pid()) -> ok.
register_circuit(Node, CircuitId, CircuitPid) ->
    gen_server:cast(?SERVER, {register_circuit, Node, CircuitId, CircuitPid}).

%% @doc Unregister a circuit from a connection
-spec unregister_circuit(node(), #circuit_id{}) -> ok.
unregister_circuit(Node, CircuitId) ->
    gen_server:cast(?SERVER, {unregister_circuit, Node, CircuitId}).

%%====================================================================
%% gen_server Callbacks
%%====================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    %% Create ETS tables
    ets:new(?CONN_TABLE, [named_table, protected, {read_concurrency, true}]),
    ets:new(?PORT_TABLE, [named_table, public, {read_concurrency, true}]),

    %% Get configuration
    ListenPort = maps:get(listen_port,
        Opts, application:get_env(mycelium, circuit_listen_port, 0)),
    ConnectTimeout = maps:get(connect_timeout,
        Opts, application:get_env(mycelium, circuit_connect_timeout, 5000)),
    HeartbeatInterval = maps:get(heartbeat_interval,
        Opts, application:get_env(mycelium, circuit_heartbeat_interval, 10000)),
    DeadInterval = maps:get(dead_interval,
        Opts, application:get_env(mycelium, circuit_dead_interval, 30000)),
    AuthEnabled = maps:get(auth_enabled,
        Opts, application:get_env(mycelium, auth_enabled, true)),

    %% Start listener
    case start_listener(ListenPort) of
        {ok, ListenSocket, ActualPort} ->
            %% Register our circuit port
            register_circuit_port(ActualPort),

            %% Start acceptor
            AcceptorPid = spawn_link(fun() -> acceptor_loop(ListenSocket, AuthEnabled) end),

            State = #state{
                listener = ListenSocket,
                listen_port = ActualPort,
                acceptor_pid = AcceptorPid,
                connect_timeout = ConnectTimeout,
                heartbeat_interval = HeartbeatInterval,
                dead_interval = DeadInterval,
                auth_enabled = AuthEnabled
            },
            {ok, State};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call({get_connection, Node}, _From, State) ->
    Reply = do_get_connection(Node, State),
    {reply, Reply, State};

handle_call({connect, Node, _Opts}, _From, State) ->
    Reply = do_connect(Node, State),
    {reply, Reply, State};

handle_call(list_connections, _From, State) ->
    Conns = ets:foldl(fun({Node, Conn}, Acc) ->
        ConnMap = #{
            socket => Conn#conn.socket,
            direction => Conn#conn.direction,
            circuits => sets:size(Conn#conn.circuits),
            created_at => Conn#conn.created_at,
            last_pong => Conn#conn.last_pong
        },
        [{Node, ConnMap} | Acc]
    end, [], ?CONN_TABLE),
    {reply, Conns, State};

handle_call(get_listen_port, _From, State) ->
    {reply, State#state.listen_port, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({register_circuit, Node, CircuitId, CircuitPid}, State) ->
    do_register_circuit(Node, CircuitId, CircuitPid),
    {noreply, State};

handle_cast({unregister_circuit, Node, CircuitId}, State) ->
    do_unregister_circuit(Node, CircuitId),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({new_connection, Socket, PeerNode}, State) ->
    %% Accepted connection from acceptor
    add_inbound_connection(PeerNode, Socket, State),
    {noreply, State};

handle_info({tcp_closed, Socket}, State) ->
    handle_connection_down(Socket, closed, State),
    {noreply, State};

handle_info({tcp_error, Socket, Reason}, State) ->
    handle_connection_down(Socket, Reason, State),
    {noreply, State};

handle_info({pong, Node}, State) ->
    %% Received PONG from peer
    update_last_pong(Node),
    {noreply, State};

handle_info({send_ping, Node}, State) ->
    %% Time to send a PING
    send_ping(Node, State),
    {noreply, State};

handle_info({check_dead, Node}, State) ->
    %% Check if connection is dead (no PONG received)
    check_connection_dead(Node, State),
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, State) when Pid =:= State#state.acceptor_pid ->
    %% Acceptor crashed, restart it
    NewPid = spawn_link(fun() ->
        acceptor_loop(State#state.listener, State#state.auth_enabled)
    end),
    case Reason of
        normal -> ok;
        _ -> ok
    end,
    {noreply, State#state{acceptor_pid = NewPid}};

handle_info({'EXIT', Pid, _Reason}, State) ->
    %% A receiver process died
    handle_receiver_down(Pid, State),
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% A circuit process died - unregister it
    handle_circuit_down(Pid),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Close all connections
    ets:foldl(fun({_Node, Conn}, _) ->
        gen_tcp:close(Conn#conn.socket),
        ok
    end, ok, ?CONN_TABLE),
    %% Close listener
    case State#state.listener of
        undefined -> ok;
        Socket -> gen_tcp:close(Socket)
    end,
    ok.

%%====================================================================
%% Internal Functions - Connection Management
%%====================================================================

do_get_connection(Node, State) ->
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            {ok, {tcp, Conn#conn.socket, self()}};
        [] ->
            %% No existing connection, create one
            do_connect(Node, State)
    end.

do_connect(Node, State) ->
    %% Check if already connected
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            {ok, {tcp, Conn#conn.socket, self()}};
        [] ->
            %% Need to establish new connection
            case get_peer_address(Node) of
                {ok, Host, Port} ->
                    TcpOpts = [binary, {active, false}, {packet, 4}, {nodelay, true}],
                    case gen_tcp:connect(Host, Port, TcpOpts, State#state.connect_timeout) of
                        {ok, Socket} ->
                            case maybe_authenticate(Socket, Node, State#state.auth_enabled) of
                                ok ->
                                    %% Send our node name and port
                                    send_hello(Socket, State#state.listen_port),
                                    %% Start receiver
                                    ReceiverPid = start_receiver(Socket),
                                    Now = erlang:monotonic_time(millisecond),
                                    %% Start heartbeat timer
                                    PingTimer = schedule_ping(Node, State#state.heartbeat_interval),
                                    Conn = #conn{
                                        socket = Socket,
                                        node = Node,
                                        direction = outbound,
                                        circuits = sets:new(),
                                        circuit_pids = #{},
                                        created_at = Now,
                                        last_pong = Now,
                                        receiver = ReceiverPid,
                                        ping_timer = PingTimer
                                    },
                                    ets:insert(?CONN_TABLE, {Node, Conn}),
                                    {ok, {tcp, Socket, self()}};
                                {error, Reason} ->
                                    gen_tcp:close(Socket),
                                    {error, {auth_failed, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {connect_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {resolve_failed, Reason}}
            end
    end.

add_inbound_connection(Node, Socket, State) ->
    %% Check if we already have a connection to this node
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, _ExistingConn}] ->
            %% Already have a connection, close the new one
            gen_tcp:close(Socket);
        [] ->
            %% Accept the new connection
            ReceiverPid = start_receiver(Socket),
            Now = erlang:monotonic_time(millisecond),
            PingTimer = schedule_ping(Node, State#state.heartbeat_interval),
            Conn = #conn{
                socket = Socket,
                node = Node,
                direction = inbound,
                circuits = sets:new(),
                circuit_pids = #{},
                created_at = Now,
                last_pong = Now,
                receiver = ReceiverPid,
                ping_timer = PingTimer
            },
            ets:insert(?CONN_TABLE, {Node, Conn})
    end.

do_register_circuit(Node, CircuitId, CircuitPid) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            %% Monitor the circuit process
            erlang:monitor(process, CircuitPid),
            NewCircuits = sets:add_element(Key, Conn#conn.circuits),
            NewPids = maps:put(CircuitPid, Key, Conn#conn.circuit_pids),
            ets:insert(?CONN_TABLE, {Node, Conn#conn{
                circuits = NewCircuits,
                circuit_pids = NewPids
            }});
        [] ->
            ok
    end.

do_unregister_circuit(Node, CircuitId) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            NewCircuits = sets:del_element(Key, Conn#conn.circuits),
            %% Find and remove the pid mapping
            NewPids = maps:filter(fun(_Pid, K) -> K =/= Key end, Conn#conn.circuit_pids),
            NewConn = Conn#conn{circuits = NewCircuits, circuit_pids = NewPids},
            %% If no more circuits, close the connection
            case sets:is_empty(NewCircuits) of
                true ->
                    cancel_timer(Conn#conn.ping_timer),
                    exit(Conn#conn.receiver, shutdown),
                    gen_tcp:close(Conn#conn.socket),
                    ets:delete(?CONN_TABLE, Node);
                false ->
                    ets:insert(?CONN_TABLE, {Node, NewConn})
            end;
        [] ->
            ok
    end.

handle_circuit_down(CircuitPid) ->
    %% Find which connection this circuit was on
    ets:foldl(fun({Node, Conn}, _) ->
        case maps:get(CircuitPid, Conn#conn.circuit_pids, undefined) of
            undefined ->
                ok;
            Key ->
                NewCircuits = sets:del_element(Key, Conn#conn.circuits),
                NewPids = maps:remove(CircuitPid, Conn#conn.circuit_pids),
                NewConn = Conn#conn{circuits = NewCircuits, circuit_pids = NewPids},
                case sets:is_empty(NewCircuits) of
                    true ->
                        cancel_timer(Conn#conn.ping_timer),
                        exit(Conn#conn.receiver, shutdown),
                        gen_tcp:close(Conn#conn.socket),
                        ets:delete(?CONN_TABLE, Node);
                    false ->
                        ets:insert(?CONN_TABLE, {Node, NewConn})
                end
        end,
        ok
    end, ok, ?CONN_TABLE).

handle_connection_down(Socket, Reason, _State) ->
    %% Find the connection by socket and notify all circuits
    case find_conn_by_socket(Socket) of
        {ok, Node, Conn} ->
            cancel_timer(Conn#conn.ping_timer),
            %% Notify all circuits on this connection
            notify_circuits_down(Conn, Reason),
            ets:delete(?CONN_TABLE, Node);
        not_found ->
            ok
    end.

handle_receiver_down(ReceiverPid, _State) ->
    case find_conn_by_receiver(ReceiverPid) of
        {ok, Node, Conn} ->
            cancel_timer(Conn#conn.ping_timer),
            notify_circuits_down(Conn, receiver_crashed),
            gen_tcp:close(Conn#conn.socket),
            ets:delete(?CONN_TABLE, Node);
        not_found ->
            ok
    end.

notify_circuits_down(Conn, Reason) ->
    %% Send transport_down to all circuit pids
    maps:foreach(fun(Pid, _Key) ->
        Pid ! {transport_down, Conn#conn.node, Reason}
    end, Conn#conn.circuit_pids).

find_conn_by_socket(Socket) ->
    ets:foldl(fun
        ({Node, Conn}, not_found) when Conn#conn.socket =:= Socket ->
            {ok, Node, Conn};
        (_, Acc) ->
            Acc
    end, not_found, ?CONN_TABLE).

find_conn_by_receiver(Pid) ->
    ets:foldl(fun
        ({Node, Conn}, not_found) when Conn#conn.receiver =:= Pid ->
            {ok, Node, Conn};
        (_, Acc) ->
            Acc
    end, not_found, ?CONN_TABLE).

%%====================================================================
%% Internal Functions - Heartbeat
%%====================================================================

schedule_ping(Node, Interval) ->
    erlang:send_after(Interval, self(), {send_ping, Node}).

send_ping(Node, State) ->
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            %% Send PING control message (IdLen=0)
            PingFrame = <<0:8, ?CIRCUIT_PING:8>>,
            case gen_tcp:send(Conn#conn.socket, PingFrame) of
                ok ->
                    %% Schedule dead check
                    erlang:send_after(State#state.dead_interval, self(), {check_dead, Node}),
                    %% Schedule next ping
                    NewTimer = schedule_ping(Node, State#state.heartbeat_interval),
                    ets:insert(?CONN_TABLE, {Node, Conn#conn{ping_timer = NewTimer}});
                {error, _Reason} ->
                    %% Send failed, connection is probably dead
                    handle_connection_down(Conn#conn.socket, send_failed, State)
            end;
        [] ->
            ok
    end.

update_last_pong(Node) ->
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            Now = erlang:monotonic_time(millisecond),
            ets:insert(?CONN_TABLE, {Node, Conn#conn{last_pong = Now}});
        [] ->
            ok
    end.

check_connection_dead(Node, State) ->
    case ets:lookup(?CONN_TABLE, Node) of
        [{_, Conn}] ->
            Now = erlang:monotonic_time(millisecond),
            TimeSinceLastPong = Now - Conn#conn.last_pong,
            case TimeSinceLastPong > State#state.dead_interval of
                true ->
                    %% Connection is dead
                    handle_connection_down(Conn#conn.socket, heartbeat_timeout, State);
                false ->
                    ok
            end;
        [] ->
            ok
    end.

%%====================================================================
%% Internal Functions - Listener & Acceptor
%%====================================================================

start_listener(Port) ->
    TcpOpts = [binary, {active, false}, {packet, 4}, {reuseaddr, true}, {nodelay, true}],
    case gen_tcp:listen(Port, TcpOpts) of
        {ok, Socket} ->
            {ok, {_, ActualPort}} = inet:sockname(Socket),
            {ok, Socket, ActualPort};
        Error ->
            Error
    end.

acceptor_loop(ListenSocket, AuthEnabled) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            case accept_connection(Socket, AuthEnabled) of
                {ok, PeerNode} ->
                    %% Transfer socket ownership to the main process
                    gen_tcp:controlling_process(Socket, whereis(?SERVER)),
                    ?SERVER ! {new_connection, Socket, PeerNode};
                {error, _Reason} ->
                    gen_tcp:close(Socket)
            end,
            acceptor_loop(ListenSocket, AuthEnabled);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            acceptor_loop(ListenSocket, AuthEnabled)
    end.

accept_connection(Socket, AuthEnabled) ->
    case AuthEnabled of
        true ->
            case do_accept_auth(Socket) of
                {ok, PeerNode, PeerPort} ->
                    %% Store peer's circuit port
                    ets:insert(?PORT_TABLE, {PeerNode, PeerPort}),
                    {ok, PeerNode};
                Error ->
                    Error
            end;
        false ->
            %% Just receive hello
            case receive_hello(Socket) of
                {ok, PeerNode, PeerPort} ->
                    ets:insert(?PORT_TABLE, {PeerNode, PeerPort}),
                    {ok, PeerNode};
                Error ->
                    Error
            end
    end.

do_accept_auth(Socket) ->
    %% Simplified auth for circuit connections
    %% Reuse Ed25519 challenge-response from dist_auth
    Timeout = application:get_env(mycelium, auth_handshake_timeout, 10000),
    case mycelium_dist_auth:get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            %% Receive peer's hello first
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, HelloData} ->
                    case decode_hello(HelloData) of
                        {ok, PeerNode, PeerPort, PeerPubKey} ->
                            %% Send our hello
                            HelloMsg = encode_hello(MyNode, MyPubKey,
                                application:get_env(mycelium, circuit_listen_port, 0)),
                            case gen_tcp:send(Socket, HelloMsg) of
                                ok ->
                                    %% Do challenge-response
                                    do_challenge_response(Socket, PeerNode, PeerPort,
                                        PeerPubKey, Timeout);
                                {error, Reason} ->
                                    {error, {send_hello_failed, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {decode_hello_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {recv_hello_failed, Reason}}
            end;
        Error ->
            Error
    end.

do_challenge_response(Socket, PeerNode, PeerPort, PeerPubKey, Timeout) ->
    %% Create and send challenge
    {MyNonce, MyTimestamp} = mycelium_dist_auth:create_challenge(),
    ChallengeMsg = <<MyNonce/binary, MyTimestamp:64/big>>,
    case gen_tcp:send(Socket, ChallengeMsg) of
        ok ->
            %% Receive peer's challenge
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, <<PeerNonce:32/binary, PeerTimestamp:64/big>>} ->
                    %% Sign peer's challenge
                    case mycelium_dist_auth:sign_challenge(PeerNonce, PeerTimestamp) of
                        {ok, MySignature} ->
                            %% Send our response
                            case gen_tcp:send(Socket, MySignature) of
                                ok ->
                                    %% Receive peer's response
                                    case gen_tcp:recv(Socket, 0, Timeout) of
                                        {ok, PeerSignature} ->
                                            %% Verify
                                            case mycelium_dist_auth:verify_response(
                                                    PeerSignature, PeerPubKey,
                                                    {MyNonce, MyTimestamp}) of
                                                true ->
                                                    {ok, PeerNode, PeerPort};
                                                false ->
                                                    {error, signature_verification_failed}
                                            end;
                                        {error, Reason} ->
                                            {error, {recv_response_failed, Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, {send_response_failed, Reason}}
                            end;
                        Error ->
                            Error
                    end;
                {error, Reason} ->
                    {error, {recv_challenge_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {send_challenge_failed, Reason}}
    end.

maybe_authenticate(Socket, Node, true) ->
    Timeout = application:get_env(mycelium, auth_handshake_timeout, 10000),
    case mycelium_dist_auth:get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            ListenPort = application:get_env(mycelium, circuit_listen_port, 0),
            %% Send our hello
            HelloMsg = encode_hello(MyNode, MyPubKey, ListenPort),
            case gen_tcp:send(Socket, HelloMsg) of
                ok ->
                    %% Receive peer's hello
                    case gen_tcp:recv(Socket, 0, Timeout) of
                        {ok, HelloData} ->
                            case decode_hello(HelloData) of
                                {ok, PeerNode, PeerPort, PeerPubKey} when PeerNode =:= Node ->
                                    %% Store peer port
                                    ets:insert(?PORT_TABLE, {PeerNode, PeerPort}),
                                    %% Do challenge-response (initiator side)
                                    do_challenge_response_initiator(Socket, PeerPubKey, Timeout);
                                {ok, PeerNode, _, _} ->
                                    {error, {node_mismatch, {expected, Node}, {got, PeerNode}}};
                                {error, Reason} ->
                                    {error, {decode_hello_failed, Reason}}
                            end;
                        {error, Reason} ->
                            {error, {recv_hello_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {send_hello_failed, Reason}}
            end;
        Error ->
            Error
    end;
maybe_authenticate(_Socket, _Node, false) ->
    ok.

do_challenge_response_initiator(Socket, PeerPubKey, Timeout) ->
    %% Receive peer's challenge first (we're the initiator)
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, <<PeerNonce:32/binary, PeerTimestamp:64/big>>} ->
            %% Create our challenge
            {MyNonce, MyTimestamp} = mycelium_dist_auth:create_challenge(),
            ChallengeMsg = <<MyNonce/binary, MyTimestamp:64/big>>,
            case gen_tcp:send(Socket, ChallengeMsg) of
                ok ->
                    %% Sign peer's challenge
                    case mycelium_dist_auth:sign_challenge(PeerNonce, PeerTimestamp) of
                        {ok, MySignature} ->
                            %% Receive peer's response first
                            case gen_tcp:recv(Socket, 0, Timeout) of
                                {ok, PeerSignature} ->
                                    %% Verify
                                    case mycelium_dist_auth:verify_response(
                                            PeerSignature, PeerPubKey,
                                            {MyNonce, MyTimestamp}) of
                                        true ->
                                            %% Send our response
                                            case gen_tcp:send(Socket, MySignature) of
                                                ok -> ok;
                                                {error, Reason} ->
                                                    {error, {send_response_failed, Reason}}
                                            end;
                                        false ->
                                            {error, signature_verification_failed}
                                    end;
                                {error, Reason} ->
                                    {error, {recv_response_failed, Reason}}
                            end;
                        Error ->
                            Error
                    end;
                {error, Reason} ->
                    {error, {send_challenge_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {recv_challenge_failed, Reason}}
    end.

%%====================================================================
%% Internal Functions - Receiver
%%====================================================================

start_receiver(Socket) ->
    Parent = self(),
    spawn_link(fun() -> receiver_loop(Socket, Parent) end).

receiver_loop(Socket, Parent) ->
    inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Data} ->
            case decode_frame(Data) of
                {ok, CircuitId, Payload} ->
                    %% Route to protocol handler
                    mycelium_circuit_protocol:handle_message(unknown, Payload, undefined),
                    %% CircuitId is used for routing context
                    _ = CircuitId,
                    receiver_loop(Socket, Parent);
                {control, ?CIRCUIT_PING} ->
                    %% Send PONG back
                    PongFrame = <<0:8, ?CIRCUIT_PONG:8>>,
                    gen_tcp:send(Socket, PongFrame),
                    receiver_loop(Socket, Parent);
                {control, ?CIRCUIT_PONG} ->
                    %% Notify parent of PONG
                    case find_node_by_socket(Socket, Parent) of
                        {ok, Node} ->
                            Parent ! {pong, Node};
                        not_found ->
                            ok
                    end,
                    receiver_loop(Socket, Parent);
                {error, _Reason} ->
                    %% Frame decode error - close connection
                    Parent ! {tcp_error, Socket, decode_error},
                    ok
            end;
        {tcp_closed, Socket} ->
            Parent ! {tcp_closed, Socket},
            ok;
        {tcp_error, Socket, Reason} ->
            Parent ! {tcp_error, Socket, Reason},
            ok;
        _ ->
            receiver_loop(Socket, Parent)
    end.

find_node_by_socket(Socket, _Parent) ->
    %% Find the node for this socket from ETS
    ets:foldl(fun
        ({Node, Conn}, not_found) when Conn#conn.socket =:= Socket ->
            {ok, Node};
        (_, Acc) ->
            Acc
    end, not_found, ?CONN_TABLE).

%%====================================================================
%% Internal Functions - Wire Protocol
%%====================================================================

%% Frame format: <<CircuitIdLen:8, CircuitId/binary, Payload/binary>>
%% Control messages: <<0:8, Type:8>> where IdLen=0
%% Note: {packet, 4} handles the outer frame length

encode_frame(CircuitId, Payload) ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<IdLen:8, IdBin/binary, Payload/binary>>.

decode_frame(<<0:8, Type:8>>) ->
    %% Control message
    {control, Type};
decode_frame(<<IdLen:8, IdBin:IdLen/binary, Payload/binary>>) ->
    case decode_circuit_id(IdBin) of
        {ok, CircuitId} ->
            {ok, CircuitId, Payload};
        {error, Reason} ->
            {error, {invalid_circuit_id, Reason}}
    end;
decode_frame(_) ->
    {error, invalid_frame}.

encode_circuit_id(#circuit_id{id = Id, initiator = Initiator}) ->
    InitBin = atom_to_binary(Initiator, utf8),
    InitLen = byte_size(InitBin),
    <<Id/binary, InitLen:8, InitBin/binary>>.

decode_circuit_id(<<Id:16/binary, InitLen:8, InitBin:InitLen/binary>>) ->
    Initiator = binary_to_atom(InitBin, utf8),
    {ok, #circuit_id{id = Id, initiator = Initiator}};
decode_circuit_id(_) ->
    {error, invalid_format}.

%%====================================================================
%% Internal Functions - Hello Protocol
%%====================================================================

%% Hello message: <<NodeLen:16, Node/binary, Port:16, PubKeyLen:8, PubKey/binary>>
encode_hello(Node, PubKey, Port) ->
    NodeBin = atom_to_binary(Node, utf8),
    NodeLen = byte_size(NodeBin),
    PubKeyLen = byte_size(PubKey),
    <<NodeLen:16, NodeBin/binary, Port:16, PubKeyLen:8, PubKey/binary>>.

decode_hello(<<NodeLen:16, NodeBin:NodeLen/binary, Port:16,
               PubKeyLen:8, PubKey:PubKeyLen/binary>>) ->
    Node = binary_to_atom(NodeBin, utf8),
    {ok, Node, Port, PubKey};
decode_hello(_) ->
    {error, invalid_hello}.

receive_hello(Socket) ->
    Timeout = application:get_env(mycelium, auth_handshake_timeout, 10000),
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            case decode_hello(Data) of
                {ok, Node, Port, _PubKey} ->
                    %% Send our hello back (without auth)
                    MyNode = node(),
                    MyPort = application:get_env(mycelium, circuit_listen_port, 0),
                    HelloMsg = encode_hello(MyNode, <<>>, MyPort),
                    case gen_tcp:send(Socket, HelloMsg) of
                        ok -> {ok, Node, Port};
                        Error -> Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

send_hello(Socket, Port) ->
    MyNode = node(),
    case mycelium_dist_auth:get_public_key() of
        {ok, PubKey} ->
            HelloMsg = encode_hello(MyNode, PubKey, Port),
            gen_tcp:send(Socket, HelloMsg);
        {error, _} ->
            HelloMsg = encode_hello(MyNode, <<>>, Port),
            gen_tcp:send(Socket, HelloMsg)
    end.

%%====================================================================
%% Internal Functions - Peer Discovery
%%====================================================================

get_peer_address(Node) ->
    %% First check if we have stored the peer's circuit port
    case ets:lookup(?PORT_TABLE, Node) of
        [{_, Port}] ->
            case get_node_host(Node) of
                {ok, Host} -> {ok, Host, Port};
                Error -> Error
            end;
        [] ->
            %% Try to get from HyParView peer info
            case mycelium_hyparview:get_peer(Node) of
                {ok, Peer} when Peer#peer.port =/= undefined ->
                    %% Use distribution port + 1 as circuit port convention
                    %% Or use configured offset
                    Offset = application:get_env(mycelium, circuit_port_offset, 1),
                    CircuitPort = Peer#peer.port + Offset,
                    case Peer#peer.address of
                        undefined ->
                            case get_node_host(Node) of
                                {ok, Host} -> {ok, Host, CircuitPort};
                                Error -> Error
                            end;
                        Address ->
                            {ok, Address, CircuitPort}
                    end;
                _ ->
                    %% Fallback: get host from node name, use default port
                    case get_node_host(Node) of
                        {ok, Host} ->
                            DefaultPort = application:get_env(mycelium, circuit_listen_port, 4370),
                            {ok, Host, DefaultPort};
                        Error ->
                            Error
                    end
            end
    end.

get_node_host(Node) ->
    NodeStr = atom_to_list(Node),
    case string:split(NodeStr, "@") of
        [_, Host] ->
            case inet:parse_address(Host) of
                {ok, Addr} -> {ok, Addr};
                {error, _} ->
                    case inet:getaddr(Host, inet) of
                        {ok, Addr} -> {ok, Addr};
                        {error, _} ->
                            case inet:getaddr(Host, inet6) of
                                {ok, Addr} -> {ok, Addr};
                                Error -> Error
                            end
                    end
            end;
        _ ->
            {error, invalid_node_name}
    end.

register_circuit_port(Port) ->
    %% Store our own circuit port for peer discovery
    ets:insert(?PORT_TABLE, {node(), Port}).

circuit_key(#circuit_id{id = Id, initiator = Initiator}) ->
    {Id, Initiator}.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).
