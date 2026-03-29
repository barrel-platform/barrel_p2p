-module(mycelium_dist_tls).

%% OTP Alt-Dist Callbacks (required by net_kernel)
-export([listen/1, accept/1, accept_connection/5, setup/5, close/1, select/1]).

%% Optional callbacks
-export([address/0, is_node_name/1, setopts/2, getopts/2]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

-define(FAMILY, inet).

%%====================================================================
%% OTP Alt-Dist Callbacks
%%====================================================================

%% @doc Create TLS listen socket and register with EPMD
-spec listen(atom()) -> {ok, {term(), #net_address{}, 1..3}} | {error, term()}.
listen(Name) ->
    Port = get_listen_port(),
    TlsOpts = get_server_tls_opts(),
    case ssl:listen(Port, listen_opts() ++ TlsOpts) of
        {ok, Socket} ->
            {ok, {_IP, ActualPort}} = ssl:sockname(Socket),
            case erl_epmd:register_node(Name, ActualPort) of
                {ok, Creation} ->
                    {ok, Host} = inet:gethostname(),
                    NetAddr = #net_address{
                        address = {0, 0, 0, 0},
                        host = Host,
                        protocol = tls,
                        family = ?FAMILY
                    },
                    {ok, {Socket, NetAddr, Creation}};
                Error ->
                    ssl:close(Socket),
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Spawn acceptor process
-spec accept(term()) -> pid().
accept({ListenSocket, _NetAddr, _Creation}) ->
    Kernel = self(),
    spawn_opt(fun() -> accept_loop(Kernel, ListenSocket) end, [link]).

%% @doc Handle incoming connection handshake
-spec accept_connection(pid(), term(), node(), term(), non_neg_integer()) -> pid().
accept_connection(AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    spawn_opt(fun() ->
        do_accept(AcceptPid, DistCtrl, MyNode, Allowed, SetupTime)
    end, dist_util:net_ticker_spawn_options()).

%% @doc Initiate outbound connection
-spec setup(node(), atom(), node(), atom(), non_neg_integer()) -> pid().
setup(Node, Type, MyNode, LongOrShort, SetupTime) ->
    spawn_opt(fun() ->
        do_setup(Node, Type, MyNode, LongOrShort, SetupTime)
    end, dist_util:net_ticker_spawn_options()).

%% @doc Close listener
-spec close(term()) -> ok.
close({ListenSocket, _NetAddr, _Creation}) ->
    ssl:close(ListenSocket).

%% @doc Check if this transport handles the given node
-spec select(node()) -> boolean().
select(Node) ->
    is_node_name(Node).

%% @doc Check if atom is a valid node name
-spec is_node_name(term()) -> boolean().
is_node_name(Node) when is_atom(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_Name, _Host] -> true;
        _ -> false
    end;
is_node_name(_) ->
    false.

%% @doc Return default address info
-spec address() -> #net_address{}.
address() ->
    {ok, Host} = inet:gethostname(),
    #net_address{
        host = Host,
        protocol = tls,
        family = ?FAMILY
    }.

%% @doc Set socket options
-spec setopts(term(), list()) -> ok.
setopts(_Socket, _Opts) ->
    ok.

%% @doc Get socket options
-spec getopts(term(), list()) -> {ok, list()}.
getopts(_Socket, _Opts) ->
    {ok, []}.

%%====================================================================
%% Accept Loop
%%====================================================================

accept_loop(Kernel, ListenSocket) ->
    case ssl:transport_accept(ListenSocket) of
        {ok, Socket} ->
            case ssl:handshake(Socket, get_handshake_timeout()) of
                {ok, SslSocket} ->
                    case verify_peer(SslSocket) of
                        true ->
                            %% Ed25519 authentication before OTP handshake
                            case mycelium_dist_auth:authenticate_incoming(SslSocket) of
                                ok ->
                                    Kernel ! {accept, self(), SslSocket, ?FAMILY, tls},
                                    receive
                                        {Kernel, controller, Pid} ->
                                            ok = ssl:controlling_process(SslSocket, Pid),
                                            Pid ! {self(), controller};
                                        {Kernel, unsupported_protocol} ->
                                            ssl:close(SslSocket)
                                    end,
                                    accept_loop(Kernel, ListenSocket);
                                {error, _Reason} ->
                                    ssl:close(SslSocket),
                                    accept_loop(Kernel, ListenSocket)
                            end;
                        false ->
                            ssl:close(SslSocket),
                            accept_loop(Kernel, ListenSocket)
                    end;
                {error, _} ->
                    accept_loop(Kernel, ListenSocket)
            end;
        {error, closed} ->
            ok;
        Error ->
            exit(Error)
    end.

verify_peer(_Socket) ->
    %% Could implement certificate verification here
    true.

%%====================================================================
%% Connection Setup (Outbound)
%%====================================================================

do_setup(Node, Type, MyNode, LongOrShort, SetupTime) ->
    Timer = dist_util:start_timer(SetupTime),
    case split_node(Node, LongOrShort) of
        {node, Name, Host} ->
            case erl_epmd:port_please(Name, Host) of
                {port, Port, Version} ->
                    dist_util:reset_timer(Timer),
                    TlsOpts = get_client_tls_opts(),
                    Timeout = time_left(Timer),
                    case ssl:connect(Host, Port, connect_opts() ++ TlsOpts, Timeout) of
                        {ok, Socket} ->
                            %% Ed25519 authentication before OTP handshake
                            case mycelium_dist_auth:authenticate_outgoing(Socket, Node) of
                                ok ->
                                    HSData = make_hs_data_outgoing(Socket, Node, MyNode, Timer, Type, Version),
                                    dist_util:handshake_we_started(HSData);
                                {error, _Reason} ->
                                    ssl:close(Socket),
                                    ?shutdown(Node)
                            end;
                        {error, _Reason} ->
                            ?shutdown(Node)
                    end;
                _ ->
                    ?shutdown(Node)
            end;
        _ ->
            ?shutdown(Node)
    end.

%%====================================================================
%% Connection Accept (Inbound)
%%====================================================================

do_accept(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    receive
        {AcceptPid, controller} ->
            Timer = dist_util:start_timer(SetupTime),
            HSData = make_hs_data_incoming(Socket, MyNode, Timer, Allowed),
            dist_util:handshake_other_started(HSData)
    end.

%%====================================================================
%% Handshake Data
%%====================================================================

make_hs_data_outgoing(Socket, Node, MyNode, Timer, Type, Version) ->
    ssl:setopts(Socket, [{active, false}, {packet, 2}]),
    #hs_data{
        kernel_pid = self(),
        other_node = Node,
        this_node = MyNode,
        socket = Socket,
        timer = Timer,
        this_flags = 0,
        other_version = Version,
        f_send = fun ssl_send/2,
        f_recv = fun ssl_recv/3,
        f_setopts_pre_nodeup = fun ssl_setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun ssl_setopts_post_nodeup/1,
        f_getll = fun ssl_getll/1,
        f_address = fun(_, _) -> ssl_address(Socket, Node) end,
        mf_tick = fun ssl_tick/1,
        mf_getstat = fun ssl_getstat/1,
        request_type = Type,
        mf_setopts = fun ssl_setopts/2,
        mf_getopts = fun ssl_getopts/2
    }.

make_hs_data_incoming(Socket, MyNode, Timer, Allowed) ->
    ssl:setopts(Socket, [{active, false}, {packet, 2}]),
    #hs_data{
        kernel_pid = self(),
        this_node = MyNode,
        socket = Socket,
        timer = Timer,
        this_flags = 0,
        allowed = Allowed,
        f_send = fun ssl_send/2,
        f_recv = fun ssl_recv/3,
        f_setopts_pre_nodeup = fun ssl_setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun ssl_setopts_post_nodeup/1,
        f_getll = fun ssl_getll/1,
        f_address = fun(S, N) -> ssl_address(S, N) end,
        mf_tick = fun ssl_tick/1,
        mf_getstat = fun ssl_getstat/1,
        mf_setopts = fun ssl_setopts/2,
        mf_getopts = fun ssl_getopts/2
    }.

%%====================================================================
%% Handshake Callback Functions
%%====================================================================

ssl_send(Socket, Data) ->
    ssl:send(Socket, Data).

ssl_recv(Socket, Length, Timeout) ->
    case ssl:recv(Socket, Length, Timeout) of
        {ok, Data} when is_list(Data) ->
            {ok, list_to_binary(Data)};
        Other ->
            Other
    end.

ssl_setopts_pre_nodeup(Socket) ->
    ssl:setopts(Socket, [{active, false}, {packet, 4}]).

ssl_setopts_post_nodeup(Socket) ->
    ssl:setopts(Socket, [{active, true}, {packet, 4}]).

ssl_getll(Socket) ->
    {ok, Socket}.

ssl_address(Socket, Node) ->
    case ssl:peername(Socket) of
        {ok, {Ip, Port}} ->
            Host = case Node of
                undefined -> "unknown";
                _ ->
                    case string:split(atom_to_list(Node), "@") of
                        [_, H] -> H;
                        _ -> "unknown"
                    end
            end,
            #net_address{
                address = {Ip, Port},
                host = Host,
                protocol = tls,
                family = ?FAMILY
            };
        {error, _} ->
            #net_address{
                address = {0, 0, 0, 0},
                host = "unknown",
                protocol = tls,
                family = ?FAMILY
            }
    end.

ssl_tick(Socket) ->
    case ssl:send(Socket, []) of
        ok -> ok;
        {error, _} -> {error, closed}
    end.

ssl_getstat(Socket) ->
    case ssl:getstat(Socket, [recv_cnt, send_cnt, send_pend]) of
        {ok, Stats} ->
            RecvCnt = proplists:get_value(recv_cnt, Stats, 0),
            SendCnt = proplists:get_value(send_cnt, Stats, 0),
            SendPend = proplists:get_value(send_pend, Stats, 0),
            {ok, RecvCnt, SendCnt, SendPend};
        Error ->
            Error
    end.

ssl_setopts(Socket, Opts) ->
    ssl:setopts(Socket, Opts).

ssl_getopts(Socket, Opts) ->
    ssl:getopts(Socket, Opts).

%%====================================================================
%% Internal Helpers
%%====================================================================

listen_opts() ->
    [binary,
     {active, false},
     {packet, 2},
     {reuseaddr, true},
     {backlog, 128}].

connect_opts() ->
    [binary,
     {active, false},
     {packet, 2}].

get_listen_port() ->
    case application:get_env(mycelium, listen_port) of
        {ok, Port} when is_integer(Port) -> Port;
        _ -> 0
    end.

get_server_tls_opts() ->
    Certfile = get_tls_opt(certfile),
    Keyfile = get_tls_opt(keyfile),
    Cacertfile = get_tls_opt(cacertfile),
    BaseOpts = [
        {verify, verify_peer},
        {fail_if_no_peer_cert, true}
    ],
    add_file_opts(BaseOpts, [
        {certfile, Certfile},
        {keyfile, Keyfile},
        {cacertfile, Cacertfile}
    ]).

get_client_tls_opts() ->
    Certfile = get_tls_opt(certfile),
    Keyfile = get_tls_opt(keyfile),
    Cacertfile = get_tls_opt(cacertfile),
    BaseOpts = [
        {verify, verify_peer}
    ],
    add_file_opts(BaseOpts, [
        {certfile, Certfile},
        {keyfile, Keyfile},
        {cacertfile, Cacertfile}
    ]).

get_tls_opt(Key) ->
    case application:get_env(mycelium_dist_tls, Key) of
        {ok, Value} -> Value;
        undefined -> undefined
    end.

add_file_opts(Opts, FileOpts) ->
    lists:foldl(fun
        ({_Key, undefined}, Acc) -> Acc;
        ({Key, Value}, Acc) -> [{Key, Value} | Acc]
    end, Opts, FileOpts).

get_handshake_timeout() ->
    case application:get_env(mycelium_dist_tls, handshake_timeout) of
        {ok, Timeout} -> Timeout;
        undefined -> 5000
    end.

%% @doc Split node name into components
%% Returns {node, Name, Host} or {error, Reason}
-spec split_node(node(), shortnames | longnames) -> {node, string(), string()} | {error, term()}.
split_node(Node, LongOrShort) when is_atom(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [Name, Host] ->
            case LongOrShort of
                longnames ->
                    case string:find(Host, ".") of
                        nomatch -> {error, not_long_name};
                        _ -> {node, Name, Host}
                    end;
                shortnames ->
                    {node, Name, Host}
            end;
        _ ->
            {error, invalid_node_name}
    end;
split_node(_, _) ->
    {error, not_atom}.

%% @doc Get remaining time from timer
%% Compatible with OTP 27+ timer format
-spec time_left(term()) -> non_neg_integer() | infinity.
time_left(Timer) ->
    case Timer of
        {deadline, Deadline} ->
            %% OTP 25+ format: {deadline, MonotonicTime}
            Now = erlang:monotonic_time(millisecond),
            max(0, Deadline - Now);
        infinity ->
            infinity;
        Timeout when is_integer(Timeout) ->
            Timeout;
        _ ->
            %% Fallback for older timer formats
            infinity
    end.
