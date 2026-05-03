%%% -*- erlang -*-
%%%
%%% Mycelium Circuit Pipe (v2)
%%%
%%% Owns the QUIC user stream(s) for a single circuit hop. Three roles:
%%%
%%%   - `initiator': originator endpoint. Owns one stream; drives
%%%     migration on unexpected close (via `mycelium_router:find_path').
%%%   - `destination': remote endpoint. Owns one stream; on
%%%     unexpected close, waits for `mycelium_circuit_relay' to
%%%     `attach_inbound/3' a fresh stream that carries a peer RESUME.
%%%   - `relay': intermediate hop. Owns two streams; splices bytes
%%%     verbatim. No link state, no migration; the initiator
%%%     re-routes if a relay link goes down.
%%%
%%% Endpoint roles wrap a `mycelium_circuit_link' for the windowed
%%% reliability protocol. Both directions are independent; the link
%%% buffers unacked DATA/FIN frames and replays them on a fresh
%%% stream after a RESUME exchange.
%%%
%%% Owner messages (sent to the pid that called
%%% `mycelium_circuit:open' or registered via
%%% `mycelium_circuit:listen'):
%%%
%%%   {circuit, CRef, {opened, FromNode}}
%%%   {circuit, CRef, {data, Data}}
%%%   {circuit, CRef, {migrating, OldPath}}
%%%   {circuit, CRef, {migrated, NewPath, EstRttUs}}
%%%   {circuit, CRef, {migration_failed, Reason}}
%%%   {circuit, CRef, closed}
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_circuit_pipe).
-behaviour(gen_server).

-export([
    start_link/1,
    send/2,
    close/1,
    info/1,
    attach_inbound/3
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_MIGRATION_TIMEOUT, 10000).
-define(DEFAULT_RESUME_HANDSHAKE_TIMEOUT, 5000).
-define(CIRCUIT_TAG, <<"mycelium:circuit">>).

-record(state, {
    role :: initiator | destination | relay,
    cref :: term(),
    circuit_id :: binary() | undefined,

    %% Endpoint roles
    stream :: quic_dist:stream_ref() | undefined,
    link :: mycelium_circuit_link:link_state() | undefined,
    owner :: pid() | undefined,
    owner_mon :: reference() | undefined,

    %% Initiator only
    target :: node() | undefined,
    full_path :: [node()] | undefined,
    repath :: boolean(),

    %% Migration state
    migrating = false :: boolean(),
    migration_timer :: reference() | undefined,
    migration_timeout :: pos_integer(),
    %% Number of FRAME_RESUMEs we still need to receive from the peer
    %% before pruning+replaying. Set to 1 when migration starts.
    awaiting_peer_resume = false :: boolean(),

    %% Backpressure: gen_server callers parked on full link or
    %% pending migration. {From, Data} pairs replayed in order.
    blocked_senders = [] :: [{term(), iodata()}],
    %% Pending close request parked behind blocked_senders.
    pending_close :: term() | undefined,

    %% Relay role
    in :: quic_dist:stream_ref() | undefined,
    out :: quic_dist:stream_ref() | undefined,
    closed_in = false :: boolean(),
    closed_out = false :: boolean()
}).

%%====================================================================
%% Public API
%%====================================================================

start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Pipe, Data) ->
    gen_server:call(Pipe, {send, Data}, infinity).

-spec close(pid()) -> ok.
close(Pipe) ->
    gen_server:call(Pipe, close, infinity).

-spec info(pid()) -> map().
info(Pipe) ->
    gen_server:call(Pipe, info).

%% @doc Used by `mycelium_circuit_relay' on the destination side
%% during migration: the relay just received a fresh inbound stream
%% carrying a `FRAME_RESUME' for an existing destination pipe;
%% transfer ownership and feed the residual bytes (which include
%% the RESUME frame) into the link.
-spec attach_inbound(pid(), quic_dist:stream_ref(), binary()) -> ok.
attach_inbound(Pipe, NewStream, Pending) ->
    gen_server:cast(Pipe, {attach_inbound, NewStream, Pending}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({initiator, Stream, CircuitId, Target, FullPath, Owner, Opts}) ->
    Mon = erlang:monitor(process, Owner),
    Link = mycelium_circuit_link:new(initiator, CircuitId),
    {ok, #state{
        role = initiator,
        cref = make_cref(CircuitId, self()),
        circuit_id = CircuitId,
        stream = Stream,
        link = Link,
        owner = Owner,
        owner_mon = Mon,
        target = Target,
        full_path = FullPath,
        repath = maps:get(repath, Opts, true),
        migration_timeout = maps:get(migration_timeout, Opts,
                                     ?DEFAULT_MIGRATION_TIMEOUT)
    }};
init({destination, Stream, CircuitId, Pending, Owner}) ->
    Mon = erlang:monitor(process, Owner),
    Link0 = mycelium_circuit_link:new(destination, CircuitId),
    %% Pending bytes are app data that arrived in the same chunk as
    %% the CREATE frame; feed them through the link so the owner sees
    %% them as the first {data, _} event.
    {Link, S} = feed_and_dispatch(Pending, Link0,
        #state{
            role = destination,
            cref = make_cref(CircuitId, self()),
            circuit_id = CircuitId,
            stream = Stream,
            link = undefined,
            owner = Owner,
            owner_mon = Mon,
            repath = true,
            migration_timeout = ?DEFAULT_MIGRATION_TIMEOUT
        }),
    {ok, S#state{link = Link}};
init({relay, In, Out, _CircuitId, Pending}) ->
    case Pending of
        <<>> -> ok;
        _    -> _ = quic_dist:send(Out, Pending)
    end,
    {ok, #state{role = relay, in = In, out = Out, repath = false,
                migration_timeout = 0}}.

%%--------------------------------------------------------------------
%% Calls
%%--------------------------------------------------------------------

handle_call({send, Data}, From,
            S = #state{role = R, migrating = Mig})
  when R =/= relay ->
    case Mig of
        true ->
            %% Park the caller until migration completes.
            {noreply, S#state{blocked_senders =
                              S#state.blocked_senders ++ [{From, Data}]}};
        false ->
            do_endpoint_send(Data, From, S)
    end;
handle_call({send, _Data}, _From, S) ->
    {reply, {error, not_endpoint}, S};
handle_call(close, From,
            S = #state{role = R, migrating = Mig})
  when R =/= relay ->
    case Mig of
        true ->
            {noreply, S#state{pending_close = From}};
        false ->
            do_endpoint_close(From, S)
    end;
handle_call(close, _From, S = #state{role = relay,
                                      in = In, out = Out}) ->
    _ = quic_dist:close_stream(In),
    _ = quic_dist:close_stream(Out),
    {stop, normal, ok, S};
handle_call(info, _From, S) ->
    {reply, info_map(S), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown}, S}.

%%--------------------------------------------------------------------
%% Casts
%%--------------------------------------------------------------------

handle_cast({attach_inbound, NewStream, Pending},
            S = #state{role = destination, migrating = true}) ->
    cancel_timer(S#state.migration_timer),
    %% Feed the residual bytes through the link; the FRAME_RESUME
    %% inside it triggers the symmetric handshake.
    {Link, S2} = feed_and_dispatch(Pending, S#state.link,
        S#state{stream = NewStream,
                migration_timer = undefined,
                migrating = true,    %% stays true until peer RESUME applied
                awaiting_peer_resume = true}),
    %% The link itself doesn't change with attach_inbound, so just
    %% replace the link state if feed_and_dispatch updated it.
    {noreply, S2#state{link = Link}};
handle_cast({attach_inbound, _, _}, S) ->
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Stream events (endpoint role)
%%--------------------------------------------------------------------

handle_info({quic_dist_stream, SR, {data, Data, Fin}},
            S = #state{role = R, stream = SR, link = Link})
  when R =/= relay ->
    {Link2, S2} = feed_and_dispatch(Data, Link, S),
    case Fin of
        true ->
            %% A FIN at the QUIC layer for this stream means peer
            %% closed it; only meaningful if the link FIN frame
            %% already came through.
            {noreply, S2#state{link = Link2}};
        false ->
            {noreply, S2#state{link = Link2}}
    end;
handle_info({quic_dist_stream, SR, closed},
            S = #state{role = R, stream = SR})
  when R =/= relay ->
    handle_unexpected_close(S);
handle_info({quic_dist_stream, SR, {stream_reset, _Code}},
            S = #state{role = R, stream = SR})
  when R =/= relay ->
    handle_unexpected_close(S);

%%--------------------------------------------------------------------
%% Stream events (relay role)
%%--------------------------------------------------------------------

handle_info({quic_dist_stream, In, {data, Data, Fin}},
            S = #state{role = relay, in = In, out = Out}) ->
    _ = quic_dist:send(Out, Data, Fin),
    case Fin of
        true  -> maybe_stop(S#state{closed_in = true});
        false -> {noreply, S}
    end;
handle_info({quic_dist_stream, Out, {data, Data, Fin}},
            S = #state{role = relay, in = In, out = Out}) ->
    _ = quic_dist:send(In, Data, Fin),
    case Fin of
        true  -> maybe_stop(S#state{closed_out = true});
        false -> {noreply, S}
    end;
handle_info({quic_dist_stream, In, closed},
            S = #state{role = relay, in = In}) ->
    maybe_stop(S#state{closed_in = true});
handle_info({quic_dist_stream, Out, closed},
            S = #state{role = relay, out = Out}) ->
    maybe_stop(S#state{closed_out = true});
handle_info({quic_dist_stream, _, {stream_reset, _}},
            S = #state{role = relay}) ->
    {stop, normal, S};

%%--------------------------------------------------------------------
%% Owner DOWN
%%--------------------------------------------------------------------

handle_info({'DOWN', Mon, process, _Pid, _Reason},
            S = #state{owner_mon = Mon, stream = SR})
  when SR =/= undefined ->
    _ = quic_dist:close_stream(SR),
    {stop, normal, S};
handle_info({'DOWN', Mon, process, _Pid, _Reason},
            S = #state{owner_mon = Mon}) ->
    {stop, normal, S};

%%--------------------------------------------------------------------
%% Migration timer
%%--------------------------------------------------------------------

handle_info({migration_timeout, Ref},
            S = #state{migration_timer = Ref, migrating = true}) ->
    notify_owner({migration_failed, timeout}, S),
    notify_owner(closed, S),
    fail_blocked_senders({error, closed}, S),
    {stop, normal, S};
handle_info({migration_timeout, _}, S) ->
    {noreply, S};

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%%====================================================================
%% Endpoint internals
%%====================================================================

do_endpoint_send(Data, From, S = #state{link = L0, stream = SR}) ->
    case mycelium_circuit_link:push_data(Data, L0) of
        {full, L1} ->
            {noreply, S#state{link = L1,
                              blocked_senders =
                                S#state.blocked_senders ++ [{From, Data}]}};
        {ok, Frame, L1} ->
            case quic_dist:send(SR, Frame) of
                ok            -> {reply, ok, S#state{link = L1}};
                {error, _} = E -> {reply, E, S#state{link = L1}}
            end
    end.

do_endpoint_close(_From, S = #state{link = L0, stream = SR}) ->
    case mycelium_circuit_link:push_fin(L0) of
        already_finned ->
            {reply, ok, S};
        {ok, Frame, L1} ->
            _ = quic_dist:send(SR, Frame),
            {reply, ok, S#state{link = L1}}
    end.

%% Feed inbound bytes into the link and process every fully-formed
%% frame, performing side effects (deliver to owner, send ACK, apply
%% RESUME, etc.) as needed. Returns {NewLink, NewState}.
feed_and_dispatch(<<>>, Link, S) ->
    {Link, S};
feed_and_dispatch(Bytes, Link, S) ->
    case mycelium_circuit_link:feed(Bytes, Link) of
        {ok, Frames, Link1} ->
            S1 = lists:foldl(fun(F, AccS) ->
                {NewLink, NewS} =
                    apply_frame(F, AccS#state.link, AccS),
                NewS#state{link = NewLink}
            end, S#state{link = Link1}, Frames),
            S2 = maybe_emit_ack(S1),
            {S2#state.link, S2};
        {error, Reason, Link1} ->
            notify_owner({migration_failed, {protocol, Reason}}, S),
            notify_owner(closed, S),
            {Link1, S}
    end.

apply_frame({data, Seq, Payload}, Link, S) ->
    case mycelium_circuit_link:apply_data(Seq, Payload, Link) of
        {deliver, Bin, Link2} ->
            notify_owner({data, Bin}, S),
            {Link2, S};
        {duplicate, Link2} ->
            {Link2, S};
        {protocol_error, Reason, Link2} ->
            notify_owner({migration_failed, {protocol, Reason}}, S),
            {Link2, S}
    end;
apply_frame({fin, Seq}, Link, S) ->
    case mycelium_circuit_link:apply_fin(Seq, Link) of
        {fin, Link2} ->
            notify_owner(closed, S),
            {Link2, S};
        {duplicate, Link2} ->
            {Link2, S};
        {protocol_error, Reason, Link2} ->
            notify_owner({migration_failed, {protocol, Reason}}, S),
            {Link2, S}
    end;
apply_frame({ack, CumSeq}, Link, S) ->
    Link2 = mycelium_circuit_link:apply_ack(CumSeq, Link),
    %% Backpressure may have eased; flush blocked senders.
    {Link3, S2} = drain_blocked(Link2, S),
    {Link3, S2};
apply_frame({resume, _Id, PeerRxNext, _Path}, Link, S) ->
    %% Peer RESUME completes our migration handshake.
    on_peer_resume(PeerRxNext, Link, S);
apply_frame({create, _Id, _Init, _Path}, Link, S) ->
    %% Endpoints don't expect CREATE on an established stream;
    %% relays don't reach this code. Silently ignore.
    {Link, S}.

%% Drain blocked_senders (and pending_close if any) when migration
%% completes or backpressure releases.
drain_blocked(Link, S = #state{migrating = true}) ->
    %% Don't drain mid-migration; wait for completion.
    {Link, S};
drain_blocked(Link, S = #state{blocked_senders = []}) ->
    drain_pending_close(Link, S);
drain_blocked(Link, S = #state{blocked_senders = [{From, Data} | Rest],
                                stream = SR}) ->
    case mycelium_circuit_link:push_data(Data, Link) of
        {full, Link2} ->
            {Link2, S};
        {ok, Frame, Link2} ->
            case quic_dist:send(SR, Frame) of
                ok ->
                    gen_server:reply(From, ok),
                    drain_blocked(Link2, S#state{blocked_senders = Rest});
                {error, _} = E ->
                    gen_server:reply(From, E),
                    {Link2, S#state{blocked_senders = Rest}}
            end
    end.

drain_pending_close(Link, S = #state{pending_close = undefined}) ->
    {Link, S};
drain_pending_close(Link, S = #state{pending_close = From, stream = SR}) ->
    case mycelium_circuit_link:push_fin(Link) of
        already_finned ->
            gen_server:reply(From, ok),
            {Link, S#state{pending_close = undefined}};
        {ok, Frame, Link2} ->
            _ = quic_dist:send(SR, Frame),
            gen_server:reply(From, ok),
            {Link2, S#state{pending_close = undefined}}
    end.

%%====================================================================
%% Migration
%%====================================================================

handle_unexpected_close(S = #state{repath = false}) ->
    notify_owner(closed, S),
    fail_blocked_senders({error, closed}, S),
    {stop, normal, S};
handle_unexpected_close(S = #state{role = initiator}) ->
    %% Tell the owner; immediately try to repath.
    DeadHop = first_hop(S#state.full_path, S#state.target),
    notify_owner({migrating, S#state.full_path}, S),
    Timer = arm_migration_timer(S),
    case attempt_repath(DeadHop, S) of
        {ok, NewStream, NewPath, EstRtt} ->
            %% NewPath is intermediate hops only (target excluded).
            %% The RESUME frame's path is what the new first hop
            %% still needs to forward through to reach the
            %% destination, i.e. tl(NewPath) ++ [Target].
            ResumePath = tl(NewPath) ++ [S#state.target],
            {ResumeFrame, Link2} =
                mycelium_circuit_link:build_resume(ResumePath, S#state.link),
            case quic_dist:send(NewStream, ResumeFrame) of
                ok ->
                    notify_owner({migrated, NewPath, EstRtt}, S),
                    {noreply, S#state{
                        stream = NewStream,
                        link = Link2,
                        full_path = NewPath,
                        migrating = true,
                        awaiting_peer_resume = true,
                        migration_timer = Timer
                    }};
                {error, Reason} ->
                    cancel_timer(Timer),
                    notify_owner({migration_failed, Reason}, S),
                    notify_owner(closed, S),
                    fail_blocked_senders({error, closed}, S),
                    {stop, normal, S}
            end;
        {error, Reason} ->
            cancel_timer(Timer),
            notify_owner({migration_failed, Reason}, S),
            notify_owner(closed, S),
            fail_blocked_senders({error, closed}, S),
            {stop, normal, S}
    end;
handle_unexpected_close(S = #state{role = destination}) ->
    notify_owner({migrating, []}, S),
    Timer = arm_migration_timer(S),
    {noreply, S#state{
        stream = undefined,
        migrating = true,
        awaiting_peer_resume = false,    %% destination expects new attach, not a peer RESUME on the dead stream
        migration_timer = Timer
    }}.

attempt_repath(DeadHop, _S = #state{target = Target, full_path = OldPath}) ->
    case mycelium_router:find_path(Target, #{exclude => [DeadHop],
                                              max_hops => 4,
                                              timeout => 200}) of
        {ok, [], EstRtt} ->
            %% Direct: target is in active view.
            case mycelium_streams:open(?CIRCUIT_TAG, Target) of
                {ok, SR} -> {ok, SR, [], EstRtt};
                {error, _} = E -> E
            end;
        {ok, [FirstHop | _] = NewPath0, EstRtt} ->
            case mycelium_streams:open(?CIRCUIT_TAG, FirstHop) of
                {ok, SR} -> {ok, SR, NewPath0, EstRtt};
                {error, _} = E -> E
            end;
        no_route ->
            %% Last-ditch: try the alternate of the previous path
            %% (cluster knowledge may be stale; the router has just
            %% probed once).
            case OldPath -- [DeadHop] of
                [] -> {error, no_route};
                [Alt | _] = AltPath ->
                    case mycelium_streams:open(?CIRCUIT_TAG, Alt) of
                        {ok, SR} -> {ok, SR, AltPath, 0};
                        {error, _} = E -> E
                    end
            end
    end.

on_peer_resume(PeerRxNext, Link, S = #state{migrating = true,
                                             stream = SR}) ->
    case mycelium_circuit_link:apply_peer_resume(PeerRxNext, [], Link) of
        {ok, ReplayFrames, Link2} ->
            %% Replay every still-unacked frame on the new stream.
            lists:foreach(fun(F) -> _ = quic_dist:send(SR, F) end,
                          ReplayFrames),
            %% Migration done. If we are the destination, also send
            %% our own RESUME (with empty Path) back.
            S2 = maybe_send_destination_resume(Link2, S),
            S3 = S2#state{migrating = false, awaiting_peer_resume = false},
            S4 = case S3#state.migration_timer of
                undefined -> S3;
                Timer    -> cancel_timer(Timer), S3#state{migration_timer = undefined}
            end,
            {Link3, S5} = drain_blocked(Link2, S4),
            {Link3, S5};
        {protocol_error, Reason, Link2} ->
            notify_owner({migration_failed, {protocol, Reason}}, S),
            notify_owner(closed, S),
            {Link2, S}
    end;
on_peer_resume(_PeerRxNext, Link, S) ->
    %% Peer RESUME outside a migration window: ignore.
    {Link, S}.

%% On the destination side, the first thing to do after the relay
%% attaches the new inbound stream is reply with our own RESUME
%% (carrying the destination's RxNextExpectedSeq, Path=[]).
maybe_send_destination_resume(Link, S = #state{role = destination,
                                                stream = SR}) ->
    {Frame, _Link2} = mycelium_circuit_link:build_resume([], Link),
    _ = quic_dist:send(SR, Frame),
    S;
maybe_send_destination_resume(_Link, S) ->
    S.

arm_migration_timer(#state{migration_timeout = T}) ->
    Ref = make_ref(),
    erlang:send_after(T, self(), {migration_timeout, Ref}),
    Ref.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) ->
    receive
        {migration_timeout, Ref} -> ok
    after 0 -> ok
    end.

first_hop([H | _], _Target) -> H;
first_hop([], Target)       -> Target;
first_hop(undefined, T)     -> T.

%%====================================================================
%% Helpers
%%====================================================================

maybe_emit_ack(S = #state{link = Link, stream = SR})
  when SR =/= undefined ->
    case mycelium_circuit_link:pending_ack(Link) of
        true ->
            case mycelium_circuit_link:take_pending_ack(Link) of
                {ok, AckFrame, Link2} ->
                    _ = quic_dist:send(SR, AckFrame),
                    S#state{link = Link2};
                none ->
                    S
            end;
        false ->
            S
    end;
maybe_emit_ack(S) ->
    S.

notify_owner(_, #state{owner = undefined}) ->
    ok;
notify_owner(Msg, #state{owner = Owner, cref = CRef}) ->
    Owner ! {circuit, CRef, Msg},
    ok.

fail_blocked_senders(_Reply, #state{blocked_senders = []}) ->
    ok;
fail_blocked_senders(Reply, #state{blocked_senders = Bs}) ->
    [gen_server:reply(From, Reply) || {From, _} <- Bs],
    ok.

maybe_stop(#state{closed_in = true, closed_out = true} = S) ->
    {stop, normal, S};
maybe_stop(S) ->
    {noreply, S}.

make_cref(Id, Pipe) ->
    {circuit_ref, Id, Pipe}.

info_map(S) ->
    #{
        role => S#state.role,
        cref => S#state.cref,
        stream => S#state.stream,
        owner => S#state.owner,
        migrating => S#state.migrating,
        blocked => length(S#state.blocked_senders)
    }.
