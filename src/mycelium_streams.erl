%%% -*- erlang -*-
%%%
%%% Mycelium tagged-stream multiplex
%%%
%%% Single user-stream acceptor for mycelium nodes. Replaces direct
%%% `quic_dist:accept_streams' calls from mycelium-internal layers
%%% (e.g. circuit_relay) and lets apps coexist on the same dist QUIC
%%% connection.
%%%
%%% Wire: every mycelium-managed user stream begins with
%%% `<<TagLen:8, Tag:TagLen/binary>>'. TagLen >= 1; values >= 1 are
%%% all valid. Apps namespace as they like (`<<"chat:rooms">>',
%%% `<<"acme.kv:put">>'); the `<<"mycelium:", _>>' prefix is
%%% reserved for mycelium internals.
%%%
%%% Ownership model: the demuxer hands each stream off after the
%%% first event. Handlers receive ONE `{mstream, SR, opened, From}'
%%% message followed by native `{quic_dist_stream, SR, _}' events
%%% delivered directly by `quic_dist'. The demuxer is off the data
%%% path; one context switch per stream open, none per data event.
%%%
%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_streams).
-behaviour(gen_server).

-export([
    start_link/0,
    register_acceptor/2,
    unregister_acceptor/1,
    open/2,
    list_acceptors/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(MAX_TAG_LEN, 255).
%% Stream-refused application error code, used when no acceptor is
%% registered for an inbound stream's tag.
-define(REFUSED_CODE, 16#100).

-record(state, {
    %% Tag -> handler pid.
    acceptors = #{} :: #{binary() => pid()},
    %% Pid -> {monitor_ref, registered_tag}; one entry per acceptor.
    acceptor_mons = #{} :: #{pid() => {reference(), binary()}},
    %% Per-inbound-stream buffer awaiting tag decode. Cleared once the
    %% preamble is fully decoded and the stream is dispatched.
    pending = #{} :: #{quic_dist:stream_ref() => binary()}
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register `Pid' as the handler for incoming streams tagged
%% `Tag'. After registration the handler receives:
%%   {mstream, StreamRef, opened, FromNode}
%% followed by the native quic_dist events:
%%   {quic_dist_stream, StreamRef, {data, Data, Fin}}
%%   {quic_dist_stream, StreamRef, closed}
%%   {quic_dist_stream, StreamRef, {stream_reset, Code}}
%% The handler can use `quic_dist:send/2,3' and
%% `quic_dist:close_stream/1' on `StreamRef'.
-spec register_acceptor(binary(), pid()) -> ok | {error, conflict}.
register_acceptor(Tag, Pid)
  when is_binary(Tag), byte_size(Tag) >= 1, byte_size(Tag) =< ?MAX_TAG_LEN,
       is_pid(Pid) ->
    gen_server:call(?SERVER, {register, Tag, Pid}).

%% @doc Remove the handler registered for `Tag'.
-spec unregister_acceptor(binary()) -> ok.
unregister_acceptor(Tag) when is_binary(Tag) ->
    gen_server:call(?SERVER, {unregister, Tag}).

%% @doc List currently registered tags and their handlers.
-spec list_acceptors() -> [{binary(), pid()}].
list_acceptors() ->
    gen_server:call(?SERVER, list_acceptors).

%% @doc Open a tagged stream to `Node'. The calling process becomes
%% the stream owner; `quic_dist:send/2,3', `quic_dist:close_stream/1',
%% and the native `{quic_dist_stream, _, _}' events all apply.
%%
%% The tag preamble is written before this call returns so the peer's
%% mycelium_streams demuxer can dispatch the stream as soon as the
%% first chunk arrives.
-spec open(binary(), node()) ->
    {ok, quic_dist:stream_ref()} | {error, term()}.
open(Tag, Node)
  when is_binary(Tag), byte_size(Tag) >= 1, byte_size(Tag) =< ?MAX_TAG_LEN,
       is_atom(Node) ->
    case quic_dist:open_stream(Node) of
        {ok, SR} ->
            Preamble = <<(byte_size(Tag)):8, Tag/binary>>,
            case quic_dist:send(SR, Preamble) of
                ok ->
                    {ok, SR};
                {error, _} = Err ->
                    _ = quic_dist:close_stream(SR),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    _ = net_kernel:monitor_nodes(true),
    case whereis(mycelium_hyparview_events) of
        undefined -> ok;
        _Pid      -> mycelium_hyparview_events:subscribe(self())
    end,
    %% Periodic reconcile loop: every second, ensure mycelium_streams
    %% is registered as the user-stream acceptor on every connected
    %% peer. Reconciliation rather than relying on {nodeup,_} alone
    %% covers the handshake race where the dist controller is still
    %% in `init_state' when nodeup fires.
    erlang:send_after(100, self(), reconcile_acceptors),
    {ok, #state{}}.

%% @private
%% Register mycelium_streams (this gen_server) as the acceptor for
%% incoming user streams from `Node'. The call is synchronous but
%% short-deadline so the gen_server isn't paused by an unresponsive
%% dist controller. mycelium_streams is permanent, so the dist
%% controller's monitor on us never fires DOWN -- the registration
%% stays valid for the lifetime of the connection.
register_self_as_acceptor(Node) ->
    Self = self(),
    case quic_dist:get_controller(Node) of
        {ok, Ctrl} ->
            try gen_statem:call(Ctrl, {accept_user_streams, Self}, 1000) of
                ok -> ok;
                _  -> error
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

handle_call({register, Tag, Pid}, _From,
            S = #state{acceptors = A, acceptor_mons = M}) ->
    case maps:find(Tag, A) of
        {ok, Pid} ->
            {reply, ok, S};
        {ok, _Other} ->
            {reply, {error, conflict}, S};
        error ->
            Mon = erlang:monitor(process, Pid),
            {reply, ok, S#state{
                acceptors = A#{Tag => Pid},
                acceptor_mons = M#{Pid => {Mon, Tag}}
            }}
    end;
handle_call({unregister, Tag}, _From,
            S = #state{acceptors = A, acceptor_mons = M}) ->
    case maps:take(Tag, A) of
        {Pid, A2} ->
            M2 = case maps:take(Pid, M) of
                {{Mon, Tag}, MRest} ->
                    erlang:demonitor(Mon, [flush]),
                    MRest;
                error ->
                    M
            end,
            {reply, ok, S#state{acceptors = A2, acceptor_mons = M2}};
        error ->
            {reply, ok, S}
    end;
handle_call(list_acceptors, _From, S = #state{acceptors = A}) ->
    {reply, maps:to_list(A), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% Dist-level: a new node joined our cluster (faster signal than
%% HyParView's peer_up). Register synchronously so the dist
%% controller has us in the acceptor pool before any inbound user
%% stream from this peer can arrive.
handle_info({nodeup, Node}, S) when is_atom(Node) ->
    _ = register_self_as_acceptor(Node),
    {noreply, S};
handle_info({nodedown, _Node}, S) ->
    {noreply, S};

handle_info({peer_up, Node}, S) when is_atom(Node) ->
    _ = register_self_as_acceptor(Node),
    {noreply, S};
handle_info({peer_down, _Node, _Reason}, S) ->
    {noreply, S};

%% Reconcile: every 500 ms, walk erlang:nodes() and re-register on
%% any peer whose dist controller is up. Cheap (gen_statem:call
%% with a short 1s timeout), idempotent on the upstream side.
handle_info(reconcile_acceptors, S) ->
    [_ = register_self_as_acceptor(N) || N <- erlang:nodes()],
    erlang:send_after(500, self(), reconcile_acceptors),
    {noreply, S};

%% Inbound stream traffic: buffer until the tag preamble is complete,
%% then dispatch.
handle_info({quic_dist_stream, SR, {data, Data, Fin}}, S) ->
    Buf0 = maps:get(SR, S#state.pending, <<>>),
    Buf = <<Buf0/binary, Data/binary>>,
    try_dispatch(SR, Buf, Fin, S);
handle_info({quic_dist_stream, SR, closed}, S) ->
    %% Stream gone before tag could be decoded; just drop the buffer.
    {noreply, S#state{pending = maps:remove(SR, S#state.pending)}};
handle_info({quic_dist_stream, _SR, _Other}, S) ->
    {noreply, S};

%% Acceptor pid died: drop its registration.
handle_info({'DOWN', Mon, process, Pid, _Reason},
            S = #state{acceptor_mons = M, acceptors = A}) ->
    case maps:take(Pid, M) of
        {{Mon, Tag}, M2} ->
            {noreply, S#state{
                acceptors = maps:remove(Tag, A),
                acceptor_mons = M2
            }};
        _ ->
            {noreply, S}
    end;

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% Try to decode `<<TagLen:8, Tag:TagLen/binary, Rest/binary>>' from
%% `Buf'. If complete, dispatch to the registered handler. If not
%% (less than 1 byte, or full TagLen but partial Tag), buffer and
%% wait for more.
try_dispatch(SR, <<TagLen:8, R0/binary>>, Fin, S)
  when byte_size(R0) >= TagLen ->
    <<Tag:TagLen/binary, Rest/binary>> = R0,
    S2 = S#state{pending = maps:remove(SR, S#state.pending)},
    dispatch(SR, Tag, Rest, Fin, S2);
try_dispatch(SR, Buf, _Fin, S) ->
    %% Either buf < 1 byte (no TagLen yet) or have TagLen but
    %% incomplete Tag. Save and wait.
    {noreply, S#state{pending = (S#state.pending)#{SR => Buf}}}.

dispatch(SR, Tag, Rest, Fin, S = #state{acceptors = A}) ->
    case maps:find(Tag, A) of
        {ok, HandlerPid} ->
            HandlerPid ! {mstream, SR, opened, element(2, SR)},
            %% Transfer ownership FIRST so any data forwards from
            %% drain_to land at the handler with it already
            %% recorded as owner; otherwise its quic_dist:send
            %% calls return {error, not_owner}.
            R = quic_dist:controlling_process(SR, HandlerPid),
            case (Rest =/= <<>>) orelse Fin of
                true ->
                    HandlerPid ! {quic_dist_stream, SR, {data, Rest, Fin}};
                false ->
                    ok
            end,
            drain_to(SR, HandlerPid),
            case R of
                ok ->
                    {noreply, S};
                {error, _Reason} ->
                    HandlerPid ! {quic_dist_stream, SR, closed},
                    {noreply, S}
            end;
        error ->
            _ = quic_dist:reset_stream(SR, ?REFUSED_CODE),
            {noreply, S}
    end.

drain_to(SR, Pid) ->
    receive
        {quic_dist_stream, SR, _} = Msg ->
            Pid ! Msg,
            drain_to(SR, Pid)
    after 0 ->
        ok
    end.
