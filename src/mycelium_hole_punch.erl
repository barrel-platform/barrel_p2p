-module(mycelium_hole_punch).
-behaviour(gen_server).

%% UDP Hole Punching for NAT Traversal
%%
%% Coordinates UDP hole punching between two peers behind NATs.
%% Uses existing relay connection for signaling.
%%
%% Protocol:
%% 1. Initiator sends HOLE_PUNCH_REQUEST via relay to target
%% 2. Target responds with HOLE_PUNCH_RESPONSE (with its candidates)
%% 3. Both sides send UDP packets to each other's candidates
%% 4. First bidirectional communication establishes the hole
%% 5. Return usable UDP socket
%%
%% Compatible NAT combinations (from viability matrix):
%% - Full Cone + Full Cone: Both can punch
%% - Full Cone + Restricted: Can punch
%% - Restricted + Restricted: Can punch
%% - Symmetric + anything: Usually fails, use relay

-include("mycelium.hrl").

%% API
-export([
    start_link/0,
    punch/2,
    punch_async/2,
    cancel/1,
    get_socket/1,
    is_viable/2
]).

%% Callbacks from circuit protocol
-export([
    handle_request/3,
    handle_response/3,
    handle_connect/3,
    handle_connected/3
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(PUNCH_TABLE, mycelium_hole_punch_sessions).
-define(DEFAULT_TIMEOUT, 10000).     %% 10 seconds
-define(DEFAULT_RETRIES, 3).         %% Number of punch attempts
-define(PUNCH_INTERVAL, 100).        %% ms between punch packets

-record(state, {
    sessions :: ets:tid()
}).

-record(session, {
    id            :: binary(),
    peer          :: node(),
    role          :: initiator | responder,
    socket        :: port() | undefined,
    our_candidates :: [#candidate{}],
    peer_candidates :: [#candidate{}] | undefined,
    status        :: pending | punching | connected | failed,
    from          :: {pid(), reference()} | undefined,
    caller        :: pid() | undefined,
    timer         :: reference() | undefined,
    retries       :: non_neg_integer(),
    created_at    :: integer()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Attempt hole punch to peer (synchronous)
-spec punch(node(), map()) -> {ok, port()} | {error, term()}.
punch(Peer, Opts) ->
    case is_hole_punch_enabled() of
        false -> {error, hole_punch_disabled};
        true ->
            Timeout = maps:get(timeout, Opts, get_timeout()),
            gen_server:call(?SERVER, {punch, Peer, Opts}, Timeout + 1000)
    end.

%% @doc Attempt hole punch to peer (asynchronous)
%% Result sent as {hole_punch, SessionId, {ok, Socket} | {error, Reason}}
-spec punch_async(node(), map()) -> {ok, binary()} | {error, term()}.
punch_async(Peer, Opts) ->
    case is_hole_punch_enabled() of
        false -> {error, hole_punch_disabled};
        true -> gen_server:call(?SERVER, {punch_async, Peer, Opts})
    end.

%% @doc Cancel an ongoing punch attempt
-spec cancel(binary()) -> ok.
cancel(SessionId) ->
    gen_server:cast(?SERVER, {cancel, SessionId}).

%% @doc Get socket from completed session
-spec get_socket(binary()) -> {ok, port()} | {error, term()}.
get_socket(SessionId) ->
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{status = connected, socket = Socket}] when Socket =/= undefined ->
            {ok, Socket};
        [#session{status = failed}] ->
            {error, failed};
        [#session{}] ->
            {error, not_ready};
        [] ->
            {error, not_found}
    end.

%% @doc Check if hole punch is viable between two NAT types
-spec is_viable(nat_type(), nat_type()) -> boolean().
is_viable(public, _) -> true;
is_viable(_, public) -> true;
is_viable(full_cone, full_cone) -> true;
is_viable(full_cone, restricted_cone) -> true;
is_viable(full_cone, port_restricted) -> true;
is_viable(restricted_cone, full_cone) -> true;
is_viable(restricted_cone, restricted_cone) -> true;
is_viable(restricted_cone, port_restricted) -> true;
is_viable(port_restricted, full_cone) -> true;
is_viable(port_restricted, restricted_cone) -> true;
is_viable(port_restricted, port_restricted) -> true;
is_viable(_, _) -> false.  %% Symmetric NAT or unknown

%%====================================================================
%% Protocol Callbacks (called from circuit protocol handler)
%%====================================================================

%% @doc Handle incoming HOLE_PUNCH_REQUEST
handle_request(FromNode, SessionId, Candidates) ->
    gen_server:cast(?SERVER, {request, FromNode, SessionId, Candidates}).

%% @doc Handle incoming HOLE_PUNCH_RESPONSE
handle_response(FromNode, SessionId, Candidates) ->
    gen_server:cast(?SERVER, {response, FromNode, SessionId, Candidates}).

%% @doc Handle incoming HOLE_PUNCH_CONNECT
handle_connect(FromNode, SessionId, ConnectInfo) ->
    gen_server:cast(?SERVER, {connect, FromNode, SessionId, ConnectInfo}).

%% @doc Handle incoming HOLE_PUNCH_CONNECTED
handle_connected(FromNode, SessionId, ConnectedInfo) ->
    gen_server:cast(?SERVER, {connected, FromNode, SessionId, ConnectedInfo}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?PUNCH_TABLE, [
        named_table,
        public,
        {keypos, #session.id},
        {read_concurrency, true}
    ]),
    {ok, #state{sessions = ?PUNCH_TABLE}}.

handle_call({punch, Peer, Opts}, From, State) ->
    case start_punch_session(Peer, Opts, From, State) of
        {ok, _SessionId} ->
            %% Reply will be sent when punch completes
            {noreply, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({punch_async, Peer, Opts}, {Pid, _}, State) ->
    case start_punch_session(Peer, Opts, undefined, State) of
        {ok, SessionId} ->
            %% Update session with caller pid
            case ets:lookup(?PUNCH_TABLE, SessionId) of
                [Session] ->
                    ets:insert(?PUNCH_TABLE, Session#session{caller = Pid});
                [] ->
                    ok
            end,
            {reply, {ok, SessionId}, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({request, FromNode, SessionId, PeerCandidates}, State) ->
    %% Received hole punch request - become responder
    handle_punch_request(FromNode, SessionId, PeerCandidates),
    {noreply, State};

handle_cast({response, _FromNode, SessionId, PeerCandidates}, State) ->
    %% Received response with peer's candidates
    handle_punch_response(SessionId, PeerCandidates),
    {noreply, State};

handle_cast({connect, FromNode, SessionId, ConnectInfo}, State) ->
    %% Peer started punching
    handle_punch_connect(FromNode, SessionId, ConnectInfo),
    {noreply, State};

handle_cast({connected, _FromNode, SessionId, _ConnectedInfo}, State) ->
    %% Peer confirmed connection
    handle_punch_connected(SessionId),
    {noreply, State};

handle_cast({cancel, SessionId}, State) ->
    cleanup_session(SessionId, cancelled),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({punch_timeout, SessionId}, State) ->
    handle_punch_timeout(SessionId),
    {noreply, State};

handle_info({retry_punch, SessionId}, State) ->
    handle_retry_punch(SessionId),
    {noreply, State};

handle_info({udp, Socket, FromIP, FromPort, Data}, State) ->
    handle_udp_message(Socket, FromIP, FromPort, Data),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Cleanup all sessions
    ets:foldl(fun(#session{id = Id}, _) ->
        cleanup_session(Id, shutdown)
    end, ok, ?PUNCH_TABLE),
    ok.

%%====================================================================
%% Internal Functions - Session Management
%%====================================================================

start_punch_session(Peer, _Opts, From, _State) ->
    %% Check viability first
    OurNat = mycelium_nat:get_nat_type(),
    case mycelium_nat_cache:get_peer_nat(Peer) of
        {ok, #nat_info{nat_type = PeerNat}} ->
            case is_viable(OurNat, PeerNat) of
                true ->
                    do_start_session(Peer, From);
                false ->
                    {error, incompatible_nat_types}
            end;
        {error, _} ->
            %% Don't know peer's NAT - try anyway
            do_start_session(Peer, From)
    end.

do_start_session(Peer, From) ->
    SessionId = crypto:strong_rand_bytes(16),

    %% Open UDP socket for punching
    case gen_udp:open(0, [binary, {active, true}]) of
        {ok, Socket} ->
            OurCandidates = mycelium_nat:get_candidates(),

            Now = erlang:monotonic_time(millisecond),
            Timeout = get_timeout(),
            TimerRef = erlang:send_after(Timeout, self(), {punch_timeout, SessionId}),

            Session = #session{
                id = SessionId,
                peer = Peer,
                role = initiator,
                socket = Socket,
                our_candidates = OurCandidates,
                peer_candidates = undefined,
                status = pending,
                from = From,
                timer = TimerRef,
                retries = get_retries(),
                created_at = Now
            },
            ets:insert(?PUNCH_TABLE, Session),

            %% Send request via relay
            send_punch_request(Peer, SessionId, OurCandidates),

            {ok, SessionId};
        {error, Reason} ->
            {error, {socket_error, Reason}}
    end.

handle_punch_request(FromNode, SessionId, PeerCandidates) ->
    %% Check if we can handle this request
    OurNat = mycelium_nat:get_nat_type(),
    case mycelium_nat_cache:get_peer_nat(FromNode) of
        {ok, #nat_info{nat_type = PeerNat}} ->
            case is_viable(OurNat, PeerNat) of
                false ->
                    %% Send failure response
                    send_punch_response(FromNode, SessionId, []);
                true ->
                    do_handle_request(FromNode, SessionId, PeerCandidates)
            end;
        {error, _} ->
            %% Try anyway
            do_handle_request(FromNode, SessionId, PeerCandidates)
    end.

do_handle_request(FromNode, SessionId, PeerCandidates) ->
    case gen_udp:open(0, [binary, {active, true}]) of
        {ok, Socket} ->
            OurCandidates = mycelium_nat:get_candidates(),
            Now = erlang:monotonic_time(millisecond),
            Timeout = get_timeout(),
            TimerRef = erlang:send_after(Timeout, self(), {punch_timeout, SessionId}),

            Session = #session{
                id = SessionId,
                peer = FromNode,
                role = responder,
                socket = Socket,
                our_candidates = OurCandidates,
                peer_candidates = PeerCandidates,
                status = punching,
                timer = TimerRef,
                retries = get_retries(),
                created_at = Now
            },
            ets:insert(?PUNCH_TABLE, Session),

            %% Send response with our candidates
            send_punch_response(FromNode, SessionId, OurCandidates),

            %% Start punching immediately
            start_punching(Session);
        {error, _} ->
            %% Can't handle - send empty response
            send_punch_response(FromNode, SessionId, [])
    end.

handle_punch_response(SessionId, PeerCandidates) ->
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{status = pending} = Session] ->
            case PeerCandidates of
                [] ->
                    %% Peer rejected
                    complete_session(SessionId, {error, peer_rejected});
                _ ->
                    %% Got candidates, start punching
                    NewSession = Session#session{
                        peer_candidates = PeerCandidates,
                        status = punching
                    },
                    ets:insert(?PUNCH_TABLE, NewSession),
                    start_punching(NewSession)
            end;
        _ ->
            ok
    end.

handle_punch_connect(_FromNode, SessionId, _ConnectInfo) ->
    %% Peer is also punching - ensure we're punching too
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{status = punching}] ->
            %% Already punching, good
            ok;
        _ ->
            ok
    end.

handle_punch_connected(SessionId) ->
    %% Peer confirmed connection established
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{status = punching} = Session] ->
            ets:insert(?PUNCH_TABLE, Session#session{status = connected}),
            complete_session(SessionId, {ok, Session#session.socket});
        [#session{status = connected}] ->
            %% Already connected
            ok;
        _ ->
            ok
    end.

handle_punch_timeout(SessionId) ->
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{retries = Retries}] when Retries > 0 ->
            %% Retry
            handle_retry_punch(SessionId);
        [#session{}] ->
            complete_session(SessionId, {error, timeout});
        [] ->
            ok
    end.

handle_retry_punch(SessionId) ->
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{retries = Retries, peer_candidates = Candidates} = Session]
          when Retries > 0, Candidates =/= undefined ->
            NewSession = Session#session{retries = Retries - 1},
            ets:insert(?PUNCH_TABLE, NewSession),
            start_punching(NewSession);
        _ ->
            ok
    end.

start_punching(#session{socket = Socket, peer_candidates = Candidates} = Session)
  when Candidates =/= undefined ->
    %% Send UDP packets to all peer candidates
    lists:foreach(fun(#candidate{address = Addr, port = Port}) ->
        %% Send a punch packet with session ID
        PunchPacket = encode_punch_packet(Session#session.id),
        gen_udp:send(Socket, Addr, Port, PunchPacket)
    end, Candidates),

    %% Notify peer we're punching
    send_punch_connect(Session#session.peer, Session#session.id, #{}),

    %% Schedule retry
    erlang:send_after(?PUNCH_INTERVAL, self(), {retry_punch, Session#session.id}),
    ok;
start_punching(_) ->
    ok.

handle_udp_message(_Socket, FromIP, FromPort, Data) ->
    case decode_punch_packet(Data) of
        {ok, SessionId, punch} ->
            %% Received punch packet - this means hole is open!
            case ets:lookup(?PUNCH_TABLE, SessionId) of
                [#session{status = Status} = Session] when Status =/= connected ->
                    %% Mark as connected and notify peer
                    ets:insert(?PUNCH_TABLE, Session#session{status = connected}),
                    send_punch_connected(Session#session.peer, SessionId,
                        #{from_ip => FromIP, from_port => FromPort}),
                    complete_session(SessionId, {ok, Session#session.socket});
                _ ->
                    ok
            end;
        {ok, SessionId, ack} ->
            %% Received acknowledgment
            handle_punch_connected(SessionId);
        {error, _} ->
            ok
    end.

complete_session(SessionId, Result) ->
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{from = From, caller = Caller, timer = Timer} = Session] ->
            cancel_timer(Timer),

            %% Reply to sync caller
            case From of
                undefined -> ok;
                {FromPid, _} = F when is_pid(FromPid) ->
                    gen_server:reply(F, Result)
            end,

            %% Notify async caller
            case Caller of
                undefined -> ok;
                CallerPid when is_pid(CallerPid) ->
                    CallerPid ! {hole_punch, SessionId, Result}
            end,

            %% Update session status
            case Result of
                {ok, _Socket} ->
                    ets:insert(?PUNCH_TABLE, Session#session{
                        status = connected,
                        from = undefined,
                        caller = undefined,
                        timer = undefined
                    });
                {error, _} ->
                    cleanup_session(SessionId, failed)
            end;
        [] ->
            ok
    end.

cleanup_session(SessionId, Reason) ->
    case ets:lookup(?PUNCH_TABLE, SessionId) of
        [#session{socket = Socket, timer = Timer, from = From, caller = Caller}] ->
            cancel_timer(Timer),
            close_socket(Socket),

            %% Notify callers of failure
            case From of
                undefined -> ok;
                {FromPid, _} = F when is_pid(FromPid) ->
                    gen_server:reply(F, {error, Reason})
            end,
            case Caller of
                undefined -> ok;
                CallerPid when is_pid(CallerPid) ->
                    CallerPid ! {hole_punch, SessionId, {error, Reason}}
            end,

            ets:delete(?PUNCH_TABLE, SessionId);
        [] ->
            ok
    end.

%%====================================================================
%% Internal Functions - Signaling
%%====================================================================

send_punch_request(Peer, SessionId, Candidates) ->
    Msg = encode_signal_message(?HOLE_PUNCH_REQUEST, SessionId, Candidates),
    send_via_relay(Peer, Msg).

send_punch_response(Peer, SessionId, Candidates) ->
    Msg = encode_signal_message(?HOLE_PUNCH_RESPONSE, SessionId, Candidates),
    send_via_relay(Peer, Msg).

send_punch_connect(Peer, SessionId, Info) ->
    Msg = encode_signal_message(?HOLE_PUNCH_CONNECT, SessionId, Info),
    send_via_relay(Peer, Msg).

send_punch_connected(Peer, SessionId, Info) ->
    Msg = encode_signal_message(?HOLE_PUNCH_CONNECTED, SessionId, Info),
    send_via_relay(Peer, Msg).

send_via_relay(Peer, Msg) ->
    %% Send signaling message via existing relay/circuit to peer
    %% This uses the HyParView or circuit infrastructure
    case lists:member(Peer, nodes()) of
        true ->
            %% Have distribution connection, send directly
            {mycelium_hole_punch, Peer} ! {hole_punch_signal, node(), Msg};
        false ->
            %% No direct connection, need to use relay
            %% For now, try to establish connection first
            case mycelium_hyparview:active_view() of
                [] ->
                    ok;  %% No peers, can't relay
                ActivePeers ->
                    %% Pick first available relay
                    [RelayPeer | _] = ActivePeers,
                    {mycelium_hole_punch, RelayPeer} ! {hole_punch_relay, Peer, node(), Msg}
            end
    end.

%%====================================================================
%% Internal Functions - Wire Format
%%====================================================================

encode_signal_message(Type, SessionId, Data) ->
    DataBin = term_to_binary(Data),
    <<Type:8, SessionId/binary, DataBin/binary>>.

%% Magic bytes for punch packets: "HP" = 0x4850
-define(PUNCH_MAGIC, 16#4850).

encode_punch_packet(SessionId) ->
    %% Simple punch packet format
    <<?PUNCH_MAGIC:16, SessionId/binary, 16#01>>.  %% HP magic, session id, punch type

decode_punch_packet(<<?PUNCH_MAGIC:16, SessionId:16/binary, 16#01>>) ->
    {ok, SessionId, punch};
decode_punch_packet(<<?PUNCH_MAGIC:16, SessionId:16/binary, 16#02>>) ->
    {ok, SessionId, ack};
decode_punch_packet(_) ->
    {error, invalid_packet}.

%%====================================================================
%% Configuration Helpers
%%====================================================================

is_hole_punch_enabled() ->
    application:get_env(mycelium, hole_punch_enabled, true).

get_timeout() ->
    application:get_env(mycelium, hole_punch_timeout, ?DEFAULT_TIMEOUT).

get_retries() ->
    application:get_env(mycelium, hole_punch_retries, ?DEFAULT_RETRIES).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).

close_socket(undefined) -> ok;
close_socket(Socket) -> gen_udp:close(Socket).
