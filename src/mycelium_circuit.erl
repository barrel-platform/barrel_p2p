%%% -*- erlang -*-
%%%
%%% Mycelium Circuits (v2)
%%%
%%% Multi-hop streams over the existing per-peer `quic_dist'
%%% connections, with byte-perfect resume across intermediate-hop
%%% failures and automatic shortest/fastest path selection.
%%%
%%% A circuit is a chain of QUIC user streams spliced together at
%%% intermediate hops. Each circuit rides on the
%%% `<<"mycelium:circuit">>' tag of the `mycelium_streams' multiplex,
%%% so applications can open their own tagged user streams alongside
%%% circuit traffic without colliding.
%%%
%%% Initiator:
%%%
%%%   {ok, CRef} = mycelium_circuit:open(Target).             %% auto-route
%%%   {ok, CRef} = mycelium_circuit:open(Target, [Hop1]).     %% explicit
%%%   {ok, CRef} = mycelium_circuit:open(Target, #{path => [], repath => false}).
%%%
%%%   ok = mycelium_circuit:send(CRef, <<"hello">>).
%%%   ok = mycelium_circuit:close(CRef).
%%%
%%%   The owner mailbox receives:
%%%     {circuit, CRef, {data, Data}}
%%%     {circuit, CRef, {migrating, OldPath}}
%%%     {circuit, CRef, {migrated, NewPath, EstRttUs}}
%%%     {circuit, CRef, {migration_failed, Reason}}
%%%     {circuit, CRef, closed}
%%%
%%% Destination:
%%%
%%%   ok = mycelium_circuit:listen().
%%%   receive
%%%       {circuit, CRef, {opened, InitiatorNode}} -> ...
%%%   end.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_circuit).

-export([
    open/1,
    open/2,
    open/3,
    send/2,
    close/1,
    listen/0,
    listen/1,
    unlisten/0,
    unlisten/1
]).

-export_type([circuit_ref/0, hop_path/0, open_opts/0]).

-define(CIRCUIT_TAG, <<"mycelium:circuit">>).

-type circuit_ref() :: {circuit_ref, Id :: binary(), Pipe :: pid()}.
-type hop_path() :: [node()].
-type open_opts() :: #{
    path => hop_path(),
    repath => boolean(),
    max_hops => pos_integer(),
    timeout => pos_integer()
}.

%%====================================================================
%% Public API
%%====================================================================

%% @doc Open a circuit to `Target' with auto-routed path. Picks the
%% lowest-RTT route via `mycelium_router:find_path/2', or fails with
%% `{error, no_route}' if no path exists.
-spec open(node()) -> {ok, circuit_ref()} | {error, term()}.
open(Target) when is_atom(Target) ->
    open(Target, #{}).

%% @doc Open a circuit with an explicit `Path' (list of intermediate
%% hops, target excluded) or with options.
-spec open(node(), hop_path() | open_opts()) ->
    {ok, circuit_ref()} | {error, term()}.
open(Target, Path) when is_atom(Target), is_list(Path) ->
    open(Target, Path, #{});
open(Target, Opts) when is_atom(Target), is_map(Opts) ->
    Path = case maps:find(path, Opts) of
        {ok, P} -> P;
        error   -> auto
    end,
    open(Target, Path, Opts).

%% @doc Open with explicit path + options.
-spec open(node(), hop_path() | auto, open_opts()) ->
    {ok, circuit_ref()} | {error, term()}.
open(Target, auto, Opts) when is_atom(Target) ->
    case mycelium_router:find_path(Target,
                                    maps:with([max_hops, exclude, timeout],
                                              Opts)) of
        {ok, Path, _EstRtt} ->
            do_open(Target, Path, Opts);
        no_route ->
            {error, no_route}
    end;
open(Target, Path, Opts) when is_atom(Target), is_list(Path) ->
    do_open(Target, Path, Opts).

do_open(Target, Path, Opts) ->
    FullPath = Path ++ [Target],
    case FullPath of
        [] ->
            {error, empty_path};
        [FirstHop | _] ->
            CircuitId = mycelium_circuit_proto:circuit_id(),
            case mycelium_streams:open(?CIRCUIT_TAG, FirstHop) of
                {ok, SR} ->
                    RestPath = tl(FullPath),
                    CreateMsg = mycelium_circuit_proto:encode_create(
                        CircuitId, node(), RestPath),
                    case quic_dist:send(SR, CreateMsg) of
                        ok ->
                            spawn_initiator_pipe(
                                SR, CircuitId, Target, Path, Opts);
                        {error, Reason} ->
                            _ = quic_dist:close_stream(SR),
                            {error, Reason}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

spawn_initiator_pipe(SR, CircuitId, Target, Path, Opts) ->
    PipeOpts = maps:with([repath, migration_timeout], Opts),
    case mycelium_circuit_sup:start_pipe_initiator(
            SR, CircuitId, Target, Path, self(), PipeOpts) of
        {ok, Pipe} ->
            drain_stream_to(SR, Pipe),
            case quic_dist:controlling_process(SR, Pipe) of
                ok ->
                    {ok, {circuit_ref, CircuitId, Pipe}};
                {error, Reason} ->
                    exit(Pipe, kill),
                    _ = quic_dist:close_stream(SR),
                    {error, Reason}
            end;
        {error, Reason} ->
            _ = quic_dist:close_stream(SR),
            {error, Reason}
    end.

%% @doc Send opaque application bytes on the circuit.
-spec send(circuit_ref(), iodata()) -> ok | {error, term()}.
send({circuit_ref, _Id, Pipe}, Data) ->
    mycelium_circuit_pipe:send(Pipe, Data).

%% @doc Close the circuit (half-close, FIN). The peer sees `closed'
%% after both directions terminate.
-spec close(circuit_ref()) -> ok.
close({circuit_ref, _Id, Pipe}) ->
    case is_process_alive(Pipe) of
        true  -> mycelium_circuit_pipe:close(Pipe);
        false -> ok
    end.

%% @doc Register the calling process as a circuit listener.
-spec listen() -> ok.
listen() ->
    listen(self()).

-spec listen(pid()) -> ok.
listen(Pid) when is_pid(Pid) ->
    mycelium_circuit_relay:add_listener(Pid).

-spec unlisten() -> ok.
unlisten() ->
    unlisten(self()).

-spec unlisten(pid()) -> ok.
unlisten(Pid) when is_pid(Pid) ->
    mycelium_circuit_relay:remove_listener(Pid).

%%====================================================================
%% Internal
%%====================================================================

drain_stream_to(SR, Pid) ->
    receive
        {quic_dist_stream, SR, _} = Msg ->
            Pid ! Msg,
            drain_stream_to(SR, Pid)
    after 0 ->
        ok
    end.
