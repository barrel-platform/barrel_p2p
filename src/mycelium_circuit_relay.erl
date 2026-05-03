%%% -*- erlang -*-
%%%
%%% Mycelium Circuit Relay / Acceptor (v2)
%%%
%%% Singleton gen_server that registers as a `mycelium_streams'
%%% acceptor for the `<<"mycelium:circuit">>' tag, then dispatches
%%% incoming circuit streams based on their first frame:
%%%
%%%   - `CREATE' with empty path -> destination role: spawn a fresh
%%%     destination pipe and hand it to one of the registered
%%%     listeners. Record `circuit_id -> dst_pipe_pid' so a later
%%%     `RESUME' on a fresh inbound stream can re-attach.
%%%   - `CREATE' with non-empty path -> relay role: open a new stream
%%%     to the next hop, write the rewritten CREATE, splice bytes.
%%%   - `RESUME' with empty path -> migration handshake reply: look
%%%     up the destination pipe by circuit id and `attach_inbound'
%%%     the new stream + residual bytes.
%%%   - `RESUME' with non-empty path -> migration handshake forward:
%%%     same as a CREATE relay, but the rewritten frame is RESUME
%%%     (preserves the RxNextExpectedSeq cursor).
%%%
%%% Listeners register via `add_listener/1' and receive
%%% `{circuit, CRef, {opened, InitNode}}' followed by the standard
%%% `{circuit, CRef, _}' message stream from the destination pipe.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_circuit_relay).
-behaviour(gen_server).

-export([
    start_link/0,
    add_listener/1,
    remove_listener/1,
    list_listeners/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(CIRCUIT_TAG, <<"mycelium:circuit">>).

-record(state, {
    %% Round-robin listener queue; monitors track liveness.
    listeners = [] :: [pid()],
    listener_mons = #{} :: #{pid() => reference()},
    %% StreamRef -> Buffer awaiting CREATE/RESUME decode.
    pending = #{} :: #{quic_dist:stream_ref() => binary()},
    %% StreamRef -> origin node (captured from `mstream` open event).
    origins = #{} :: #{quic_dist:stream_ref() => node()},
    %% CircuitId -> destination pipe pid. Used to re-attach a fresh
    %% inbound stream during migration.
    destinations = #{} :: #{binary() => pid()},
    %% Dest pipe pid -> CircuitId, for cleanup on DOWN.
    dest_mons = #{} :: #{pid() => {reference(), binary()}}
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec add_listener(pid()) -> ok.
add_listener(Pid) when is_pid(Pid) ->
    gen_server:call(?SERVER, {add_listener, Pid}).

-spec remove_listener(pid()) -> ok.
remove_listener(Pid) when is_pid(Pid) ->
    gen_server:call(?SERVER, {remove_listener, Pid}).

-spec list_listeners() -> [pid()].
list_listeners() ->
    gen_server:call(?SERVER, list_listeners).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Register as the streams acceptor for circuit traffic.
    case whereis(mycelium_streams) of
        undefined ->
            %% mycelium_streams isn't up yet; defer until after init.
            self() ! register_streams_acceptor;
        _Pid ->
            ok = mycelium_streams:register_acceptor(?CIRCUIT_TAG, self())
    end,
    {ok, #state{}}.

handle_call({add_listener, Pid}, _From, S = #state{listeners = L,
                                                    listener_mons = M}) ->
    case lists:member(Pid, L) of
        true ->
            {reply, ok, S};
        false ->
            Mon = erlang:monitor(process, Pid),
            {reply, ok, S#state{listeners = L ++ [Pid],
                                listener_mons = M#{Pid => Mon}}}
    end;
handle_call({remove_listener, Pid}, _From, S = #state{listeners = L,
                                                       listener_mons = M}) ->
    case maps:take(Pid, M) of
        {Mon, M2} ->
            erlang:demonitor(Mon, [flush]),
            {reply, ok, S#state{listeners = lists:delete(Pid, L),
                                listener_mons = M2}};
        error ->
            {reply, ok, S}
    end;
handle_call(list_listeners, _From, S) ->
    {reply, S#state.listeners, S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% Late registration with mycelium_streams (case both modules raced
%% on boot).
handle_info(register_streams_acceptor, S) ->
    case whereis(mycelium_streams) of
        undefined ->
            erlang:send_after(50, self(), register_streams_acceptor),
            {noreply, S};
        _Pid ->
            ok = mycelium_streams:register_acceptor(?CIRCUIT_TAG, self()),
            {noreply, S}
    end;

%% Streams demuxer announces a new inbound circuit stream.
handle_info({mstream, SR, opened, From}, S) ->
    {noreply, S#state{origins = (S#state.origins)#{SR => From}}};

%% Stream data: buffer until first frame is decoded, then dispatch.
handle_info({quic_dist_stream, SR, {data, Data, Fin}}, S) ->
    Buf0 = maps:get(SR, S#state.pending, <<>>),
    Buf = <<Buf0/binary, Data/binary>>,
    case mycelium_circuit_proto:try_decode(Buf) of
        {ok, {create, Id, Init, []}, Rest} ->
            S1 = clear_pending(SR, S),
            handoff_destination(SR, Id, Init, Rest, Fin, S1);
        {ok, {create, Id, _Init, [Next | More]}, Rest} ->
            S1 = clear_pending(SR, S),
            handoff_relay(SR, Id, fun mycelium_circuit_proto:encode_create/3,
                          Next, More, Rest, S1);
        {ok, {resume, Id, _RxNext, []}, _Rest} ->
            S1 = clear_pending(SR, S),
            handoff_resume_to_destination(SR, Id, Buf, S1);
        {ok, {resume, Id, RxNext, [Next | More]}, Rest} ->
            S1 = clear_pending(SR, S),
            handoff_resume_relay(SR, Id, RxNext, Next, More, Rest, S1);
        {ok, _Other, _Rest} ->
            %% Late arrivals: a frame (DATA/ACK/FIN) for a stream
            %% the relay just handed off to a pipe but the
            %% controlling_process race left this event in our
            %% mailbox. Drop silently; the pipe will already have
            %% been forwarded the relevant events via drain_to.
            {noreply, clear_pending(SR, S)};
        {more, _} ->
            {noreply, S#state{pending = (S#state.pending)#{SR => Buf}}};
        {error, _Reason} ->
            _ = quic_dist:reset_stream(SR, 1),
            {noreply, clear_pending(SR, S)}
    end;
handle_info({quic_dist_stream, SR, closed}, S) ->
    {noreply, clear_pending(SR, S)};
handle_info({quic_dist_stream, _SR, _Other}, S) ->
    {noreply, S};

%% Listener vanished: drop from list.
handle_info({'DOWN', _Ref, process, Pid, _Reason},
            S = #state{listener_mons = LMons}) when is_map_key(Pid, LMons) ->
    case maps:take(Pid, LMons) of
        {_Mon, LMons2} ->
            {noreply, S#state{listeners = lists:delete(Pid, S#state.listeners),
                              listener_mons = LMons2}};
        error ->
            {noreply, S}
    end;
%% Destination pipe vanished: drop circuit-id binding.
handle_info({'DOWN', _Ref, process, Pid, _Reason},
            S = #state{dest_mons = DMons}) when is_map_key(Pid, DMons) ->
    case maps:take(Pid, DMons) of
        {{_Mon, Id}, DMons2} ->
            {noreply, S#state{
                destinations = maps:remove(Id, S#state.destinations),
                dest_mons = DMons2
            }};
        error ->
            {noreply, S}
    end;

handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%%====================================================================
%% Dispatch
%%====================================================================

%% Destination role: spawn a destination pipe, hand it to a listener.
handoff_destination(SR, Id, Init, Pending, _Fin,
                     S = #state{listeners = L,
                                destinations = D, dest_mons = DM}) ->
    case rotate_listener(L) of
        {ok, Listener, L2} ->
            case mycelium_circuit_sup:start_pipe_destination(
                    SR, Id, Pending, Listener) of
                {ok, Pipe} ->
                    %% Transfer ownership FIRST so any forwarded
                    %% events reach the pipe with it already
                    %% recorded as owner; otherwise send_user_data
                    %% returns {error, not_owner}.
                    R = quic_dist:controlling_process(SR, Pipe),
                    drain_to(SR, Pipe),
                    case R of
                        ok ->
                            CRef = {circuit_ref, Id, Pipe},
                            Listener ! {circuit, CRef, {opened, Init}},
                            Mon = erlang:monitor(process, Pipe),
                            {noreply, S#state{
                                listeners = L2,
                                destinations = D#{Id => Pipe},
                                dest_mons = DM#{Pipe => {Mon, Id}}
                            }};
                        {error, _} ->
                            exit(Pipe, kill),
                            _ = quic_dist:reset_stream(SR, 2),
                            {noreply, S#state{listeners = L2}}
                    end;
                {error, _} ->
                    _ = quic_dist:reset_stream(SR, 3),
                    {noreply, S#state{listeners = L2}}
            end;
        none ->
            _ = quic_dist:reset_stream(SR, 4),
            {noreply, S}
    end.

%% Relay role for CREATE: open downstream, write rewritten frame,
%% splice bytes.
handoff_relay(In, Id, EncodeFun, NextHop, RestPath, Pending, S) ->
    case quic_dist_open_circuit_stream(NextHop) of
        {ok, Out} ->
            Frame = EncodeFun(Id, node(), RestPath),
            case quic_dist:send(Out, Frame) of
                ok ->
                    case mycelium_circuit_sup:start_pipe_relay(
                            In, Out, Id, Pending) of
                        {ok, Pipe} ->
                            %% Transfer ownership FIRST. The pipe
                            %% must be the recorded owner before
                            %% any forwarded events reach it,
                            %% otherwise its send_user_data
                            %% forwards return {error, not_owner}.
                            R1 = quic_dist:controlling_process(In, Pipe),
                            R2 = quic_dist:controlling_process(Out, Pipe),
                            drain_to(In, Pipe),
                            drain_to(Out, Pipe),
                            case {R1, R2} of
                                {ok, ok} ->
                                    {noreply, S};
                                _ ->
                                    exit(Pipe, kill),
                                    _ = quic_dist:reset_stream(In, 5),
                                    _ = quic_dist:reset_stream(Out, 5),
                                    {noreply, S}
                            end;
                        {error, _} ->
                            _ = quic_dist:reset_stream(In, 6),
                            _ = quic_dist:close_stream(Out),
                            {noreply, S}
                    end;
                {error, _} ->
                    _ = quic_dist:reset_stream(In, 7),
                    {noreply, S}
            end;
        {error, _} ->
            _ = quic_dist:reset_stream(In, 8),
            {noreply, S}
    end.

%% Relay role for RESUME: same shape as handoff_relay/7 above but the
%% downstream frame must preserve the RxNextExpectedSeq cursor.
handoff_resume_relay(In, Id, RxNext, NextHop, RestPath, Pending, S) ->
    Encode = fun(Id1, _Init, Path1) ->
        mycelium_circuit_proto:encode_resume(Id1, RxNext, Path1)
    end,
    handoff_relay(In, Id, Encode, NextHop, RestPath, Pending, S).

%% RESUME terminating at this node: feed the buffer to the existing
%% destination pipe via attach_inbound.
handoff_resume_to_destination(SR, Id, Buf,
                               S = #state{destinations = D}) ->
    case maps:find(Id, D) of
        {ok, Pipe} ->
            drain_to(SR, Pipe),
            case quic_dist:controlling_process(SR, Pipe) of
                ok ->
                    mycelium_circuit_pipe:attach_inbound(Pipe, SR, Buf),
                    {noreply, S};
                {error, _} ->
                    _ = quic_dist:reset_stream(SR, 9),
                    {noreply, S}
            end;
        error ->
            %% No matching destination pipe (destination crashed,
            %% or this is a bogus RESUME).
            _ = quic_dist:reset_stream(SR, 10),
            {noreply, S}
    end.

%% Open a downstream user stream for circuit traffic via the streams
%% layer (writes the tag preamble for us).
quic_dist_open_circuit_stream(NextHop) ->
    mycelium_streams:open(?CIRCUIT_TAG, NextHop).

clear_pending(SR, S) ->
    S#state{pending = maps:remove(SR, S#state.pending),
            origins = maps:remove(SR, S#state.origins)}.

%% Round-robin: pop the head, append to the tail.
rotate_listener([]) -> none;
rotate_listener([H | T]) -> {ok, H, T ++ [H]}.

%% Drain queued `{quic_dist_stream, SR, _}` events from our mailbox
%% and forward them to `Pid' before transferring stream ownership.
drain_to(SR, Pid) ->
    receive
        {quic_dist_stream, SR, _} = Msg ->
            Pid ! Msg,
            drain_to(SR, Pid)
    after 0 ->
        ok
    end.
