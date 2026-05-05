%%% -*- erlang -*-
%%%
%%% Mycelium Path Stats
%%%
%%% Thin accessor over upstream `quic:get_path_stats/1' for the
%%% per-peer dist QUIC connection. Used by `mycelium_router' to
%%% rank candidate next-hops by srtt.
%%%
%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_path_stats).

-export([summary/1, srtt/1, connection/1]).

-type summary() :: #{
    srtt => non_neg_integer(),
    latest_rtt => non_neg_integer(),
    min_rtt => non_neg_integer(),
    rtt_var => non_neg_integer(),
    cwnd => non_neg_integer(),
    bytes_in_flight => non_neg_integer(),
    in_recovery => boolean(),
    congested => boolean()
}.

-export_type([summary/0]).

%% @doc Return the full path-stats map for `Node'. Returns
%% `{error, not_connected}' if there is no current dist connection.
%%
%% NB: `quic_dist:get_controller/1' returns the dist controller
%% gen_statem, not the underlying QUIC connection. `quic:get_path_stats/1'
%% expects the connection. Until upstream exposes a get-path-stats
%% wrapper on the dist controller itself, we extract the conn pid
%% via `sys:get_state' on the dist controller. This is fragile to
%% upstream record shape changes; see TODO at module top.
-spec summary(node()) -> {ok, summary()} | {error, term()}.
summary(Node) when is_atom(Node) ->
    case connection(Node) of
        {ok, Conn} -> quic:get_path_stats(Conn);
        Err        -> Err
    end.

%% @doc Resolve a peer node to the underlying QUIC connection pid.
%% Used by `summary/1' here and by `mycelium:migrate_peer/1,2' for
%% RFC 9000 §9 path migration. Returns `{error, not_connected}' if
%% there is no current dist channel; `{error, no_conn}' if the
%% controller is alive but the connection extraction fails.
-spec connection(node()) -> {ok, pid()} | {error, term()}.
connection(Node) when is_atom(Node) ->
    case quic_dist:get_controller(Node) of
        {ok, DistCtrl} -> extract_conn(DistCtrl);
        Err            -> Err
    end.

%% Reach into the dist controller's gen_statem state and pluck the
%% `conn' field. Position-2 in the `#state{}' record (the first field
%% after the record tag, per `quic_dist_controller.erl' line 102).
%% Catches any failure and returns a generic `{error, no_conn}' so
%% callers don't propagate dialyzer-noisy reasons.
extract_conn(DistCtrl) ->
    try
        State = sys:get_state(DistCtrl, 1000),
        Conn = element(2, State),
        case is_pid(Conn) andalso erlang:is_process_alive(Conn) of
            true  -> {ok, Conn};
            false -> {error, no_conn}
        end
    catch
        _:_ -> {error, no_conn}
    end.

%% @doc Smoothed RTT in microseconds, or `{error, _}' if unavailable.
-spec srtt(node()) -> {ok, non_neg_integer()} | {error, term()}.
srtt(Node) ->
    case summary(Node) of
        {ok, #{srtt := Us}} -> {ok, Us};
        {error, _} = Err    -> Err
    end.
