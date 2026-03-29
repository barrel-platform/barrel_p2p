-module(mycelium_dist_tcp).

%% OTP Alt-Dist Callbacks (required by net_kernel)
-export([listen/1, accept/1, accept_connection/5, setup/5, close/1, select/1]).

%% Optional callbacks
-export([address/0, is_node_name/1, setopts/2, getopts/2]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

-define(DRIVER, inet_tcp).
-define(FAMILY, inet).

%%====================================================================
%% OTP Alt-Dist Callbacks
%%====================================================================

%% @doc Create listen socket and register with EPMD
-spec listen(atom()) -> {ok, {term(), #net_address{}, 1..3}} | {error, term()}.
listen(Name) ->
    %% Get configured port or use 0 (random)
    Port = get_listen_port(),
    case gen_tcp:listen(Port, listen_opts()) of
        {ok, Socket} ->
            {ok, {_IP, ActualPort}} = inet:sockname(Socket),
            case erl_epmd:register_node(Name, ActualPort) of
                {ok, Creation} ->
                    {ok, Host} = inet:gethostname(),
                    NetAddr = #net_address{
                        address = {0, 0, 0, 0},
                        host = Host,
                        protocol = tcp,
                        family = ?FAMILY
                    },
                    {ok, {Socket, NetAddr, Creation}};
                Error ->
                    gen_tcp:close(Socket),
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
        %% Handle different DistCtrl formats:
        %% - Socket (plain socket)
        %% - {Socket, BufferedData} (c-node with buffered OTP handshake data)
        %% - {Socket, {crypto, CryptoSession}} (encrypted connection)
        case DistCtrl of
            {Socket, {crypto, CryptoSession}} ->
                %% Store crypto session for encrypted send/recv
                put(mycelium_crypto_session, CryptoSession),
                do_accept(AcceptPid, Socket, MyNode, Allowed, SetupTime);
            {Socket, BufferedData} when is_binary(BufferedData) ->
                %% Store buffered data for recv_func to return first
                put(mycelium_buffered_data, BufferedData),
                do_accept(AcceptPid, Socket, MyNode, Allowed, SetupTime);
            Socket ->
                do_accept(AcceptPid, Socket, MyNode, Allowed, SetupTime)
        end
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
    gen_tcp:close(ListenSocket).

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
        protocol = tcp,
        family = ?FAMILY
    }.

%% @doc Set socket options (no-op for basic implementation)
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
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            case check_ip_access(Socket) of
                true ->
                    %% Ed25519 authentication before OTP handshake
                    case mycelium_dist_auth:authenticate_incoming(Socket) of
                        ok ->
                            %% Auth succeeded, no encryption
                            Kernel ! {accept, self(), Socket, ?FAMILY, tcp},
                            receive
                                {Kernel, controller, Pid} ->
                                    ok = gen_tcp:controlling_process(Socket, Pid),
                                    Pid ! {self(), controller};
                                {Kernel, unsupported_protocol} ->
                                    gen_tcp:close(Socket)
                            end,
                            accept_loop(Kernel, ListenSocket);
                        {ok, CryptoSession} ->
                            %% Auth succeeded with encryption - pass crypto session
                            Kernel ! {accept, self(), {Socket, {crypto, CryptoSession}}, ?FAMILY, tcp},
                            receive
                                {Kernel, controller, Pid} ->
                                    ok = gen_tcp:controlling_process(Socket, Pid),
                                    Pid ! {self(), controller, {crypto, CryptoSession}};
                                {Kernel, unsupported_protocol} ->
                                    gen_tcp:close(Socket)
                            end,
                            accept_loop(Kernel, ListenSocket);
                        {error, auth_not_attempted} ->
                            %% Peer didn't send Ed25519 HELLO (likely c-node)
                            %% Let OTP handshake proceed - cookie will be checked
                            Kernel ! {accept, self(), Socket, ?FAMILY, tcp},
                            receive
                                {Kernel, controller, Pid} ->
                                    ok = gen_tcp:controlling_process(Socket, Pid),
                                    Pid ! {self(), controller};
                                {Kernel, unsupported_protocol} ->
                                    gen_tcp:close(Socket)
                            end,
                            accept_loop(Kernel, ListenSocket);
                        {error, {auth_not_attempted, BufferedData}} ->
                            %% Peer sent OTP handshake data instead of AUTH_HELLO
                            %% Store the buffered data and let OTP handle it
                            Kernel ! {accept, self(), {Socket, BufferedData}, ?FAMILY, tcp},
                            receive
                                {Kernel, controller, Pid} ->
                                    ok = gen_tcp:controlling_process(Socket, Pid),
                                    Pid ! {self(), controller, BufferedData};
                                {Kernel, unsupported_protocol} ->
                                    gen_tcp:close(Socket)
                            end,
                            accept_loop(Kernel, ListenSocket);
                        {error, _Reason} ->
                            gen_tcp:close(Socket),
                            accept_loop(Kernel, ListenSocket)
                    end;
                false ->
                    gen_tcp:close(Socket),
                    accept_loop(Kernel, ListenSocket)
            end;
        {error, closed} ->
            ok;
        Error ->
            exit(Error)
    end.

check_ip_access(_Socket) ->
    %% Could implement IP allowlist/blocklist here
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
                    Timeout = time_left(Timer),
                    case gen_tcp:connect(Host, Port, connect_opts(), Timeout) of
                        {ok, Socket} ->
                            %% Ed25519 authentication before OTP handshake
                            case mycelium_dist_auth:authenticate_outgoing(Socket, Node) of
                                ok ->
                                    HSData = make_hs_data_outgoing(Socket, Node, MyNode, Timer, Type, Version),
                                    dist_util:handshake_we_started(HSData);
                                {ok, CryptoSession} ->
                                    %% Store crypto session for encrypted send/recv
                                    put(mycelium_crypto_session, CryptoSession),
                                    HSData = make_hs_data_outgoing(Socket, Node, MyNode, Timer, Type, Version),
                                    dist_util:handshake_we_started(HSData);
                                {error, _Reason} ->
                                    gen_tcp:close(Socket),
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
    inet:setopts(Socket, [{active, false}, {packet, 2}]),
    #hs_data{
        kernel_pid = self(),
        other_node = Node,
        this_node = MyNode,
        socket = Socket,
        timer = Timer,
        this_flags = 0,
        other_version = Version,
        f_send = fun send_func/2,
        f_recv = fun recv_func/3,
        f_setopts_pre_nodeup = fun setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun setopts_post_nodeup/1,
        f_getll = fun getll_func/1,
        f_address = fun(_, _) -> address_func(Socket, Node) end,
        mf_tick = fun tick_func/1,
        mf_getstat = fun getstat_func/1,
        request_type = Type,
        mf_setopts = fun setopts_func/2,
        mf_getopts = fun getopts_func/2
    }.

make_hs_data_incoming(Socket, MyNode, Timer, Allowed) ->
    inet:setopts(Socket, [{active, false}, {packet, 2}]),
    #hs_data{
        kernel_pid = self(),
        this_node = MyNode,
        socket = Socket,
        timer = Timer,
        this_flags = 0,
        allowed = Allowed,
        f_send = fun send_func/2,
        f_recv = fun recv_func/3,
        f_setopts_pre_nodeup = fun setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun setopts_post_nodeup/1,
        f_getll = fun getll_func/1,
        f_address = fun(S, N) -> address_func(S, N) end,
        mf_tick = fun tick_func/1,
        mf_getstat = fun getstat_func/1,
        mf_setopts = fun setopts_func/2,
        mf_getopts = fun getopts_func/2
    }.

%%====================================================================
%% Handshake Callback Functions
%%====================================================================

send_func(Socket, Data) ->
    case get(mycelium_crypto_session) of
        undefined ->
            %% No encryption
            gen_tcp:send(Socket, Data);
        Session ->
            %% Encrypt data before sending
            DataBin = iolist_to_binary(Data),
            case mycelium_crypto:encrypt(DataBin, Session, <<>>) of
                {ok, Encrypted, UpdatedSession} ->
                    put(mycelium_crypto_session, UpdatedSession),
                    %% Send length-prefixed encrypted data
                    Len = byte_size(Encrypted),
                    gen_tcp:send(Socket, <<Len:32/big, Encrypted/binary>>);
                {error, _Reason} = Error ->
                    Error
            end
    end.

recv_func(Socket, Length, Timeout) ->
    %% Check for buffered data from c-node detection
    case erase(mycelium_buffered_data) of
        undefined ->
            do_recv_maybe_encrypted(Socket, Length, Timeout);
        BufferedData when is_binary(BufferedData) ->
            %% Return buffered data first (c-node case, no encryption)
            BufferedLen = byte_size(BufferedData),
            if
                Length =:= 0 orelse BufferedLen >= Length ->
                    %% Buffered data is enough
                    {ok, BufferedData};
                true ->
                    %% Need more data - get from socket
                    Remaining = Length - BufferedLen,
                    case do_recv(Socket, Remaining, Timeout) of
                        {ok, MoreData} ->
                            {ok, <<BufferedData/binary, MoreData/binary>>};
                        Error ->
                            Error
                    end
            end
    end.

do_recv_maybe_encrypted(Socket, Length, Timeout) ->
    case get(mycelium_crypto_session) of
        undefined ->
            %% No encryption
            do_recv(Socket, Length, Timeout);
        Session ->
            %% Read length-prefixed encrypted block
            case gen_tcp:recv(Socket, 4, Timeout) of
                {ok, <<Len:32/big>>} ->
                    case gen_tcp:recv(Socket, Len, Timeout) of
                        {ok, Encrypted} ->
                            case mycelium_crypto:decrypt(Encrypted, Session, <<>>) of
                                {ok, Plaintext, UpdatedSession} ->
                                    put(mycelium_crypto_session, UpdatedSession),
                                    {ok, Plaintext};
                                {error, _Reason} = Error ->
                                    Error
                            end;
                        Error ->
                            Error
                    end;
                {ok, PartialLen} ->
                    %% Received partial length header - this shouldn't happen with {packet, N}
                    {error, {partial_length_header, PartialLen}};
                Error ->
                    Error
            end
    end.

do_recv(Socket, Length, Timeout) ->
    case gen_tcp:recv(Socket, Length, Timeout) of
        {ok, Data} when is_list(Data) ->
            {ok, list_to_binary(Data)};
        Other ->
            Other
    end.

setopts_pre_nodeup(Socket) ->
    inet:setopts(Socket, [{active, false}, {packet, 4}]).

setopts_post_nodeup(Socket) ->
    inet:setopts(Socket, [{active, true}, {packet, 4}, {deliver, port}]).

getll_func(Socket) ->
    {ok, Socket}.

address_func(Socket, Node) ->
    case inet:peername(Socket) of
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
                protocol = tcp,
                family = ?FAMILY
            };
        {error, _} ->
            #net_address{
                address = {0, 0, 0, 0},
                host = "unknown",
                protocol = tcp,
                family = ?FAMILY
            }
    end.

tick_func(Socket) ->
    case gen_tcp:send(Socket, []) of
        ok -> ok;
        {error, _} -> {error, closed}
    end.

getstat_func(Socket) ->
    case inet:getstat(Socket, [recv_cnt, send_cnt, send_pend]) of
        {ok, Stats} ->
            RecvCnt = proplists:get_value(recv_cnt, Stats, 0),
            SendCnt = proplists:get_value(send_cnt, Stats, 0),
            SendPend = proplists:get_value(send_pend, Stats, 0),
            {ok, RecvCnt, SendCnt, SendPend};
        Error ->
            Error
    end.

setopts_func(Socket, Opts) ->
    inet:setopts(Socket, Opts).

getopts_func(Socket, Opts) ->
    inet:getopts(Socket, Opts).

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
