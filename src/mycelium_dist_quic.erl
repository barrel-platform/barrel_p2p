-module(mycelium_dist_quic).

%% OTP Alt-Dist Callbacks (required by net_kernel)
-export([listen/1, accept/1, accept_connection/5, setup/5, close/1, select/1]).

%% Optional callbacks
-export([address/0, is_node_name/1, setopts/2, getopts/2]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

-define(FAMILY, inet).

%% NOTE: This module requires the 'quicer' library (https://github.com/emqx/quic)
%% Add {quicer, "0.0.x"} to your deps to use this transport.

%%====================================================================
%% OTP Alt-Dist Callbacks
%%====================================================================

%% @doc Create QUIC listen endpoint and register with EPMD
-spec listen(atom()) -> {ok, {term(), #net_address{}, 1..3}} | {error, term()}.
listen(Name) ->
    case code:which(quicer) of
        non_existing ->
            {error, quicer_not_loaded};
        _ ->
            do_listen(Name)
    end.

do_listen(Name) ->
    Port = get_listen_port(),
    QuicOpts = get_server_quic_opts(),
    case quicer:listen(Port, QuicOpts) of
        {ok, Listener} ->
            ActualPort = Port, %% QUIC listener doesn't have sockname like TCP
            case erl_epmd:register_node(Name, ActualPort) of
                {ok, Creation} ->
                    {ok, Host} = inet:gethostname(),
                    NetAddr = #net_address{
                        address = {0, 0, 0, 0},
                        host = Host,
                        protocol = quic,
                        family = ?FAMILY
                    },
                    {ok, {{Listener, Port}, NetAddr, Creation}};
                Error ->
                    quicer:close_listener(Listener),
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Spawn acceptor process
-spec accept(term()) -> pid().
accept({{Listener, _Port}, _NetAddr, _Creation}) ->
    Kernel = self(),
    spawn_opt(fun() -> accept_loop(Kernel, Listener) end, [link]).

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
close({{Listener, _Port}, _NetAddr, _Creation}) ->
    quicer:close_listener(Listener).

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
        protocol = quic,
        family = ?FAMILY
    }.

%% @doc Set socket options
-spec setopts(term(), list()) -> ok.
setopts(_Handle, _Opts) ->
    ok.

%% @doc Get socket options
-spec getopts(term(), list()) -> {ok, list()}.
getopts(_Handle, _Opts) ->
    {ok, []}.

%%====================================================================
%% Accept Loop
%%====================================================================

accept_loop(Kernel, Listener) ->
    case quicer:accept(Listener, #{}) of
        {ok, Conn} ->
            %% Accept the first bidirectional stream
            case quicer:accept_stream(Conn, #{}) of
                {ok, Stream} ->
                    Handle = {Conn, Stream},
                    Kernel ! {accept, self(), Handle, ?FAMILY, quic},
                    receive
                        {Kernel, controller, Pid} ->
                            ok = quicer:controlling_process(Stream, Pid),
                            Pid ! {self(), controller};
                        {Kernel, unsupported_protocol} ->
                            quicer:close_stream(Stream),
                            quicer:close_connection(Conn)
                    end,
                    accept_loop(Kernel, Listener);
                {error, _} ->
                    quicer:close_connection(Conn),
                    accept_loop(Kernel, Listener)
            end;
        {error, closed} ->
            ok;
        Error ->
            exit(Error)
    end.

%%====================================================================
%% Connection Setup (Outbound)
%%====================================================================

do_setup(Node, Type, MyNode, LongOrShort, SetupTime) ->
    Timer = dist_util:start_timer(SetupTime),
    case inet_tcp_dist:split_node(Node, LongOrShort) of
        {node, Name, Host} ->
            case erl_epmd:port_please(Name, Host) of
                {port, Port, Version} ->
                    dist_util:reset_timer(Timer),
                    QuicOpts = get_client_quic_opts(),
                    case quicer:connect(Host, Port, QuicOpts, dist_util:time_left(Timer)) of
                        {ok, Conn} ->
                            case quicer:start_stream(Conn, #{}) of
                                {ok, Stream} ->
                                    Handle = {Conn, Stream},
                                    HSData = make_hs_data_outgoing(Handle, Node, MyNode, Timer, Type, Version),
                                    dist_util:handshake_we_started(HSData);
                                {error, _} ->
                                    quicer:close_connection(Conn),
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

do_accept(AcceptPid, Handle, MyNode, Allowed, SetupTime) ->
    receive
        {AcceptPid, controller} ->
            Timer = dist_util:start_timer(SetupTime),
            HSData = make_hs_data_incoming(Handle, MyNode, Timer, Allowed),
            dist_util:handshake_other_started(HSData)
    end.

%%====================================================================
%% Handshake Data
%%====================================================================

make_hs_data_outgoing(Handle, Node, MyNode, Timer, Type, Version) ->
    #hs_data{
        kernel_pid = self(),
        other_node = Node,
        this_node = MyNode,
        socket = Handle,
        timer = Timer,
        this_flags = 0,
        other_version = Version,
        f_send = fun quic_send/2,
        f_recv = fun quic_recv/3,
        f_setopts_pre_nodeup = fun quic_setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun quic_setopts_post_nodeup/1,
        f_getll = fun quic_getll/1,
        f_address = fun(_, _) -> quic_address(Handle, Node) end,
        mf_tick = fun quic_tick/1,
        mf_getstat = fun quic_getstat/1,
        request_type = Type,
        mf_setopts = fun quic_setopts/2,
        mf_getopts = fun quic_getopts/2
    }.

make_hs_data_incoming(Handle, MyNode, Timer, Allowed) ->
    #hs_data{
        kernel_pid = self(),
        this_node = MyNode,
        socket = Handle,
        timer = Timer,
        this_flags = 0,
        allowed = Allowed,
        f_send = fun quic_send/2,
        f_recv = fun quic_recv/3,
        f_setopts_pre_nodeup = fun quic_setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun quic_setopts_post_nodeup/1,
        f_getll = fun quic_getll/1,
        f_address = fun(H, N) -> quic_address(H, N) end,
        mf_tick = fun quic_tick/1,
        mf_getstat = fun quic_getstat/1,
        mf_setopts = fun quic_setopts/2,
        mf_getopts = fun quic_getopts/2
    }.

%%====================================================================
%% Handshake Callback Functions
%%====================================================================

quic_send({_Conn, Stream}, Data) ->
    %% QUIC sends need length-prefixed framing
    Len = byte_size(iolist_to_binary(Data)),
    LenBin = <<Len:32/big>>,
    quicer:send(Stream, [LenBin, Data]).

quic_recv({_Conn, Stream}, _Length, Timeout) ->
    %% First read the length prefix
    case quicer:recv(Stream, 4, Timeout) of
        {ok, <<Len:32/big>>} ->
            quicer:recv(Stream, Len, Timeout);
        Other ->
            Other
    end.

quic_setopts_pre_nodeup(_Handle) ->
    ok.

quic_setopts_post_nodeup({_Conn, Stream}) ->
    quicer:setopt(Stream, active, true).

quic_getll(Handle) ->
    {ok, Handle}.

quic_address({Conn, _Stream}, Node) ->
    case quicer:peername(Conn) of
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
                protocol = quic,
                family = ?FAMILY
            };
        {error, _} ->
            #net_address{
                address = {0, 0, 0, 0},
                host = "unknown",
                protocol = quic,
                family = ?FAMILY
            }
    end.

quic_tick({_Conn, Stream}) ->
    case quicer:send(Stream, <<>>) of
        ok -> ok;
        {error, _} -> {error, closed}
    end.

quic_getstat({Conn, _Stream}) ->
    case quicer:getstat(Conn, [recv_cnt, send_cnt]) of
        {ok, Stats} ->
            RecvCnt = proplists:get_value(recv_cnt, Stats, 0),
            SendCnt = proplists:get_value(send_cnt, Stats, 0),
            {ok, RecvCnt, SendCnt, 0};
        Error ->
            Error
    end.

quic_setopts({_Conn, Stream}, Opts) ->
    case proplists:get_value(active, Opts) of
        undefined -> ok;
        Value -> quicer:setopt(Stream, active, Value)
    end.

quic_getopts(_Handle, _Opts) ->
    {ok, []}.

%%====================================================================
%% Internal Helpers
%%====================================================================

get_listen_port() ->
    case application:get_env(mycelium, listen_port) of
        {ok, Port} when is_integer(Port), Port > 0 -> Port;
        _ -> 9100  %% QUIC requires explicit port
    end.

get_server_quic_opts() ->
    Certfile = get_quic_opt(certfile),
    Keyfile = get_quic_opt(keyfile),
    BaseOpts = #{
        alpn => ["erlang-dist"],
        idle_timeout_ms => 30000
    },
    add_quic_file_opts(BaseOpts, [
        {certfile, Certfile},
        {keyfile, Keyfile}
    ]).

get_client_quic_opts() ->
    Certfile = get_quic_opt(certfile),
    Keyfile = get_quic_opt(keyfile),
    Cacertfile = get_quic_opt(cacertfile),
    BaseOpts = #{
        alpn => ["erlang-dist"],
        verify => verify_peer,
        idle_timeout_ms => 30000
    },
    add_quic_file_opts(BaseOpts, [
        {certfile, Certfile},
        {keyfile, Keyfile},
        {cacertfile, Cacertfile}
    ]).

get_quic_opt(Key) ->
    case application:get_env(mycelium_dist_quic, Key) of
        {ok, Value} -> Value;
        undefined -> undefined
    end.

add_quic_file_opts(Opts, FileOpts) ->
    lists:foldl(fun
        ({_Key, undefined}, Acc) -> Acc;
        ({Key, Value}, Acc) -> maps:put(Key, Value, Acc)
    end, Opts, FileOpts).
