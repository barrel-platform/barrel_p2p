-module(mycelium_circuit_transport_quic).
-behaviour(gen_server).
-behaviour(mycelium_circuit_transport).

%% QUIC Transport for Circuit Traffic
%%
%% Multiplexes circuits as user streams on top of the existing
%% quic_dist Erlang-distribution connection. One stream per circuit
%% direction. No separate listener: streams ride the dist QUIC
%% connection that net_kernel already established.
%%
%% Wire format (per-stream, identical to TCP transport):
%%   <<CircuitIdLen:8, CircuitId/binary, Payload/binary>>
%%
%% Pre-condition: Erlang must be booted with `-proto_dist quic_dist'
%% so dist connections to peers are QUIC. Identification, auth and
%% keepalive are inherited from the dist layer; nodedown drops every
%% stream to the disconnected peer.

-include("mycelium.hrl").

%% Behaviour callbacks
-export([
    start_link/1,
    connect/2,
    send/3,
    close/1,
    get_connection/1,
    release_connection/2,
    register_circuit/3,
    unregister_circuit/2
]).

%% Introspection
-export([
    list_connections/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(STREAM_TABLE, mycelium_quic_streams).

-record(state, {}).

%% One row per circuit-stream. Keyed on circuit_key/1 (the {Id, Initiator}
%% pair) so lookups from inbound frames find the right entry without
%% scanning. We also build a secondary index by stream_ref via match-spec
%% when an inbound message lands.
-record(stream_state, {
    key          :: {binary(), node()},
    stream_ref   :: term(),       %% {quic_dist_stream, Node, StreamId}
    node         :: node(),
    circuit_id   :: #circuit_id{},
    circuit_pid  :: pid() | undefined,
    monitor_ref  :: reference() | undefined,
    last_active  :: integer()
}).

%%====================================================================
%% Behaviour callbacks
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

%% @doc Open a stream for a circuit. The behaviour passes a Node here;
%% the actual stream is bound to a circuit at register time. We return
%% an opaque handle that send/3 understands.
-spec connect(node(), map()) -> {ok, mycelium_circuit_transport:conn_ref()} | {error, term()}.
connect(Node, _Opts) ->
    case is_dist_connected(Node) of
        true  -> {ok, {quic_conn, Node}};
        false -> {error, not_connected}
    end.

%% @doc Send a circuit-framed payload. We look up (or open) the stream
%% bound to {Node, CircuitId} and write the frame. The `quic_conn'
%% handle from get_connection/1 carries only the node; the circuit
%% identifies the stream.
-spec send(mycelium_circuit_transport:conn_ref(), #circuit_id{}, binary()) ->
    ok | {error, term()}.
send({quic_conn, Node}, CircuitId, Data) ->
    Frame = encode_frame(CircuitId, Data),
    case ensure_stream(Node, CircuitId) of
        {ok, StreamRef} ->
            quic_dist:send(StreamRef, Frame);
        {error, _} = Err ->
            Err
    end;
send({quic, StreamRef}, CircuitId, Data) ->
    %% Direct send on a known stream ref (kept for symmetry with the
    %% original skeleton; not used by the behaviour dispatcher).
    Frame = encode_frame(CircuitId, Data),
    quic_dist:send(StreamRef, Frame).

-spec close(mycelium_circuit_transport:conn_ref()) -> ok.
close({quic_conn, _Node}) ->
    ok;
close({quic, StreamRef}) ->
    _ = quic_dist:close_stream(StreamRef),
    ok.

-spec get_connection(node()) -> {ok, mycelium_circuit_transport:conn_ref()} | {error, term()}.
get_connection(Node) ->
    case is_dist_connected(Node) of
        true  -> {ok, {quic_conn, Node}};
        false -> {error, not_connected}
    end.

-spec release_connection(node(), mycelium_circuit_transport:conn_ref()) -> ok.
release_connection(_Node, _ConnRef) ->
    %% Streams stay open for the lifetime of the circuit.
    ok.

-spec register_circuit(node(), #circuit_id{}, pid()) -> ok.
register_circuit(Node, CircuitId, CircuitPid) ->
    gen_server:cast(?SERVER, {register_circuit, Node, CircuitId, CircuitPid}).

-spec unregister_circuit(node(), #circuit_id{}) -> ok.
unregister_circuit(Node, CircuitId) ->
    gen_server:cast(?SERVER, {unregister_circuit, Node, CircuitId}).

%%====================================================================
%% Introspection
%%====================================================================

-spec list_connections() -> [{node(), map()}].
list_connections() ->
    gen_server:call(?SERVER, list_connections).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Opts) ->
    process_flag(trap_exit, true),
    ets:new(?STREAM_TABLE, [named_table, public, {keypos, #stream_state.key}]),
    %% Watch dist for new and lost peers.
    ok = net_kernel:monitor_nodes(true),
    %% Register as user-stream acceptor for everyone we already see.
    lists:foreach(fun register_acceptor/1, nodes()),
    {ok, #state{}}.

handle_call(list_connections, _From, State) ->
    Streams = ets:tab2list(?STREAM_TABLE),
    Reply = [{S#stream_state.node,
              #{circuit_id  => S#stream_state.circuit_id,
                stream_ref  => S#stream_state.stream_ref,
                last_active => S#stream_state.last_active}}
             || S <- Streams],
    {reply, Reply, State};
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

handle_info({quic_dist_stream, StreamRef, {data, Data, _Fin}}, State) ->
    handle_stream_data(StreamRef, Data),
    {noreply, State};
handle_info({quic_dist_stream, StreamRef, closed}, State) ->
    handle_stream_gone(StreamRef, closed),
    {noreply, State};
handle_info({quic_dist_stream, StreamRef, {reset, _ErrorCode}}, State) ->
    handle_stream_gone(StreamRef, reset),
    {noreply, State};
handle_info({nodeup, Node}, State) ->
    register_acceptor(Node),
    {noreply, State};
handle_info({nodedown, Node}, State) ->
    drop_streams_for_node(Node, nodedown),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    drop_streams_for_pid(Pid),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ets:foldl(fun(#stream_state{stream_ref = Ref}, _) ->
                  catch quic_dist:close_stream(Ref),
                  ok
              end, ok, ?STREAM_TABLE),
    ok.

%%====================================================================
%% Internal: stream lifecycle
%%====================================================================

ensure_stream(Node, CircuitId) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?STREAM_TABLE, Key) of
        [#stream_state{stream_ref = Ref}] ->
            {ok, Ref};
        [] ->
            case open_stream(Node) of
                {ok, Ref} ->
                    insert_stream(Key, Ref, Node, CircuitId, undefined),
                    {ok, Ref};
                {error, _} = Err ->
                    Err
            end
    end.

open_stream(Node) ->
    case is_dist_connected(Node) of
        true ->
            case quic_dist:open_stream(Node, [{priority, 128}]) of
                {ok, Ref}      -> {ok, Ref};
                {error, R}     -> {error, {open_stream_failed, R}}
            end;
        false ->
            {error, not_connected}
    end.

do_register_circuit(Node, CircuitId, CircuitPid) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?STREAM_TABLE, Key) of
        [#stream_state{} = SS] ->
            MRef = monitor_pid(SS#stream_state.monitor_ref, CircuitPid),
            ets:insert(?STREAM_TABLE, SS#stream_state{
                circuit_pid  = CircuitPid,
                monitor_ref  = MRef,
                last_active  = now_ms()
            });
        [] ->
            case open_stream(Node) of
                {ok, Ref} ->
                    insert_stream(Key, Ref, Node, CircuitId, CircuitPid);
                {error, _Reason} ->
                    %% Initiator hasn't yet connected the dist channel,
                    %% or the peer is gone. The circuit will retry on
                    %% next send and we'll insert lazily.
                    ok
            end
    end.

do_unregister_circuit(_Node, CircuitId) ->
    Key = circuit_key(CircuitId),
    case ets:take(?STREAM_TABLE, Key) of
        [#stream_state{stream_ref = Ref, monitor_ref = MRef}] ->
            demonitor_pid(MRef),
            catch quic_dist:close_stream(Ref),
            ok;
        [] ->
            ok
    end.

insert_stream(Key, Ref, Node, CircuitId, CircuitPid) ->
    MRef = monitor_pid(undefined, CircuitPid),
    SS = #stream_state{
        key          = Key,
        stream_ref   = Ref,
        node         = Node,
        circuit_id   = CircuitId,
        circuit_pid  = CircuitPid,
        monitor_ref  = MRef,
        last_active  = now_ms()
    },
    ets:insert(?STREAM_TABLE, SS).

monitor_pid(OldRef, undefined) ->
    OldRef;
monitor_pid(OldRef, Pid) when is_pid(Pid) ->
    demonitor_pid(OldRef),
    erlang:monitor(process, Pid).

demonitor_pid(undefined) -> ok;
demonitor_pid(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref, [flush]),
    ok.

%%====================================================================
%% Internal: inbound dispatch
%%====================================================================

handle_stream_data(StreamRef, Data) ->
    case decode_frame(Data) of
        {ok, CircuitId, Payload} ->
            %% Match TCP transport: protocol layer doesn't need From here;
            %% the encoded message carries its own circuit_id, and relay
            %% forwarding decisions key off mycelium_circuit_relay state.
            _ = mycelium_circuit_protocol:handle_message(unknown, Payload, undefined),
            bind_inbound_stream(StreamRef, CircuitId),
            touch_stream(CircuitId);
        {error, _Reason} ->
            ok
    end.

bind_inbound_stream(StreamRef, CircuitId) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?STREAM_TABLE, Key) of
        [#stream_state{stream_ref = StreamRef}] ->
            ok;
        [#stream_state{} = SS] ->
            ets:insert(?STREAM_TABLE, SS#stream_state{stream_ref = StreamRef});
        [] ->
            Node = node_of_stream(StreamRef),
            insert_stream(Key, StreamRef, Node, CircuitId, undefined)
    end.

touch_stream(CircuitId) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?STREAM_TABLE, Key) of
        [#stream_state{} = SS] ->
            ets:insert(?STREAM_TABLE, SS#stream_state{last_active = now_ms()});
        [] ->
            ok
    end.

handle_stream_gone(StreamRef, Reason) ->
    case find_by_stream_ref(StreamRef) of
        {ok, #stream_state{key = Key, node = Node, circuit_pid = Pid}} ->
            ets:delete(?STREAM_TABLE, Key),
            notify_circuit(Pid, Node, Reason);
        not_found ->
            ok
    end.

drop_streams_for_node(Node, Reason) ->
    Streams = ets:match_object(?STREAM_TABLE, #stream_state{node = Node, _ = '_'}),
    lists:foreach(
      fun(#stream_state{key = Key, circuit_pid = Pid, monitor_ref = MRef}) ->
              demonitor_pid(MRef),
              ets:delete(?STREAM_TABLE, Key),
              notify_circuit(Pid, Node, Reason)
      end, Streams).

drop_streams_for_pid(Pid) ->
    Streams = ets:match_object(?STREAM_TABLE, #stream_state{circuit_pid = Pid, _ = '_'}),
    lists:foreach(
      fun(#stream_state{key = Key, stream_ref = Ref}) ->
              ets:delete(?STREAM_TABLE, Key),
              catch quic_dist:close_stream(Ref)
      end, Streams).

notify_circuit(undefined, _Node, _Reason) -> ok;
notify_circuit(Pid, Node, Reason) when is_pid(Pid) ->
    Pid ! {transport_down, Node, Reason},
    ok.

find_by_stream_ref(StreamRef) ->
    case ets:match_object(?STREAM_TABLE, #stream_state{stream_ref = StreamRef, _ = '_'}) of
        [SS | _] -> {ok, SS};
        []       -> not_found
    end.

%%====================================================================
%% Internal: dist helpers
%%====================================================================

is_dist_connected(Node) ->
    Node =:= node() orelse lists:member(Node, nodes()).

register_acceptor(Node) when Node =:= nonode@nohost -> ok;
register_acceptor(Node) ->
    catch quic_dist:accept_streams(Node),
    ok.

node_of_stream({quic_dist_stream, Node, _StreamId}) -> Node;
node_of_stream(_)                                   -> undefined.

now_ms() ->
    erlang:monotonic_time(millisecond).

%%====================================================================
%% Wire format (identical to TCP transport)
%%====================================================================

encode_frame(CircuitId, Payload) ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<IdLen:8, IdBin/binary, Payload/binary>>.

decode_frame(<<IdLen:8, IdBin:IdLen/binary, Payload/binary>>) when IdLen > 0 ->
    case decode_circuit_id(IdBin) of
        {ok, CircuitId} -> {ok, CircuitId, Payload};
        {error, R}      -> {error, {invalid_circuit_id, R}}
    end;
decode_frame(_) ->
    {error, invalid_frame}.

encode_circuit_id(#circuit_id{id = Id, initiator = Initiator}) ->
    InitBin = atom_to_binary(Initiator, utf8),
    InitLen = byte_size(InitBin),
    <<Id/binary, InitLen:8, InitBin/binary>>.

decode_circuit_id(<<Id:16/binary, InitLen:8, InitBin:InitLen/binary>>) ->
    {ok, #circuit_id{id = Id, initiator = binary_to_atom(InitBin, utf8)}};
decode_circuit_id(_) ->
    {error, invalid_format}.

circuit_key(#circuit_id{id = Id, initiator = Initiator}) ->
    {Id, Initiator}.
