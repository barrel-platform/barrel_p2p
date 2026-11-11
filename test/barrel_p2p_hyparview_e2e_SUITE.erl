%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% HyParView on real peers: active views of 2 over 5 nodes, every node
%%% joining through the same seed, so forward-joins and evictions happen.
%%% The overlay must settle into symmetric, connected active views without
%%% any HyParView server restarting, and stay that way after a node dies.
%%% The same properties are model-checked in spec/tla/HyParView.tla.
-module(barrel_p2p_hyparview_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

suite() ->
    [{timetrap, {minutes, 5}}].

all() ->
    [views_settle_symmetric_and_connected, survivors_reconnect_after_node_death].

init_per_suite(Config) ->
    BasePort = 25000 + erlang:phash2({?MODULE, erlang:system_time()}, 800) * 10,
    [{base_port, BasePort} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    SuiteDir = ?config(priv_dir, Config),
    TcDir = filename:join(
        SuiteDir,
        "tc_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join(TcDir, "dummy")),
    DiscoveryDir = filename:join(TcDir, "discovery"),
    ok = filelib:ensure_dir(filename:join(DiscoveryDir, "dummy")),
    put(?MODULE, []),
    [{tc_dir, TcDir}, {discovery_dir, DiscoveryDir} | Config].

end_per_testcase(_Case, _Config) ->
    Peers =
        case get(?MODULE) of
            undefined -> [];
            L -> L
        end,
    [
        try
            peer:stop(P)
        catch
            _:_ -> ok
        end
     || P <- Peers
    ],
    erase(?MODULE),
    ok.

%%====================================================================
%% Cases
%%====================================================================

views_settle_symmetric_and_connected(Config) ->
    Peers = start_overlay(5, Config),
    Pids = hyparview_pids(Peers),
    ok = wait_until(fun() -> settled(Peers) end, 60000),
    ?assertEqual(Pids, hyparview_pids(Peers)).

survivors_reconnect_after_node_death(Config) ->
    Peers = start_overlay(5, Config),
    ok = wait_until(fun() -> settled(Peers) end, 60000),
    [{Victim, _} | Survivors] = lists:reverse(Peers),
    Pids = hyparview_pids(Survivors),
    ok = peer:stop(Victim),
    ok = wait_until(fun() -> settled(Survivors) end, 60000),
    ?assertEqual(Pids, hyparview_pids(Survivors)).

%%====================================================================
%% Overlay checks
%%====================================================================

start_overlay(N, Config) ->
    {Peers, _} = lists:foldl(
        fun(I, {Acc, C}) ->
            {P, Node, _, C1} = start_peer("n" ++ integer_to_list(I), C),
            {Acc ++ [{P, Node}], C1}
        end,
        {[], Config},
        lists:seq(1, N)
    ),
    [{_, Seed} | Rest] = Peers,
    [
        begin
            ok = wait_until(fun() -> connect_ok(P, Seed) end, 30000),
            ok = peer:call(P, barrel_p2p, join, [Seed])
        end
     || {P, _} <- Rest
    ],
    Peers.

views(Peers) ->
    maps:from_list([{N, peer:call(P, barrel_p2p, active_view, [])} || {P, N} <- Peers]).

%% Symmetric, non-empty and connected over the given peers.
settled(Peers) ->
    V = views(Peers),
    Nodes = maps:keys(V),
    Symmetric = lists:all(
        fun(A) -> lists:all(fun(B) -> lists:member(A, maps:get(B, V, [])) end, maps:get(A, V)) end,
        Nodes
    ),
    Symmetric andalso reach([hd(Nodes)], V, []) =:= lists:sort(Nodes).

reach([], _V, Seen) ->
    lists:sort(Seen);
reach([X | Rest], V, Seen) ->
    case lists:member(X, Seen) of
        true -> reach(Rest, V, Seen);
        false -> reach(Rest ++ [Y || Y <- maps:get(X, V, []), maps:is_key(Y, V)], V, [X | Seen])
    end.

hyparview_pids(Peers) ->
    [peer:call(P, erlang, whereis, [barrel_p2p_hyparview]) || {P, _} <- Peers].

connect_ok(P, N) ->
    peer:call(P, net_kernel, connect_node, [N], 15000) =:= true andalso
        lists:member(N, peer:call(P, erlang, nodes, [])).

%%====================================================================
%% Peer setup (mirrors barrel_p2p_map_e2e_SUITE, active views of 2)
%%====================================================================

start_peer(Suffix, Config) ->
    Port = next_port(?config(base_port, Config)),
    Name = list_to_atom(
        "myc_" ++ Suffix ++ "_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    {Pid, Node} = spawn_peer(Suffix, Name, Port, Config),
    %% The 3rd element is a restart token: same Suffix/Name/Port reuses the
    %% node identity and (per-node) data dirs, so a restarted node recovers
    %% its persisted maps from disk.
    {Pid, Node, {Suffix, Name, Port}, Config}.

spawn_peer(Suffix, Name, Port, Config) ->
    TcDir = ?config(tc_dir, Config),
    NodeDir = filename:join(TcDir, Suffix),
    QuicDir = filename:join(NodeDir, "data/quic"),
    KeysDir = filename:join(NodeDir, "data/keys"),
    RemindersDir = filename:join(NodeDir, "data/reminders"),
    MapsDir = filename:join(NodeDir, "data/maps"),
    [
        ok = filelib:ensure_dir(filename:join(D, "dummy"))
     || D <- [QuicDir, KeysDir, RemindersDir, MapsDir]
    ],
    DiscoveryDir = ?config(discovery_dir, Config),
    BaseArgs = [
        "-proto_dist",
        "barrel_p2p",
        "-epmd_module",
        "barrel_p2p_epmd",
        "-start_epmd",
        "false",
        "-barrel_p2p_dist_port",
        integer_to_list(Port),
        "-barrel_p2p_dist_cert_dir",
        QuicDir,
        "-setcookie",
        "barrel_p2p_ct",
        "-barrel_p2p",
        "auth_key_dir",
        quote(KeysDir),
        "-barrel_p2p",
        "discovery_dir",
        quote(DiscoveryDir),
        %% Per-node persistence dirs, so peers do not collide on one dir and
        %% a restart recovers this node's state.
        "-barrel_p2p",
        "reminder_data_dir",
        quote(RemindersDir),
        "-barrel_p2p",
        "barrel_p2p_map_data_dir",
        quote(MapsDir),
        "-barrel_p2p",
        "active_size",
        "2",
        "-barrel_p2p",
        "member_heartbeat_ms",
        "500",
        "-barrel_p2p",
        "member_ttl_ms",
        "2000",
        "-barrel_p2p",
        "member_skew_ms",
        "60000"
    ],
    PaArgs = lists:flatmap(fun(P) -> ["-pa", P] end, code:get_path()),
    Args = PaArgs ++ BaseArgs,
    {ok, Pid, Node} = peer:start(#{
        name => Name,
        longnames => true,
        host => "127.0.0.1",
        connection => standard_io,
        args => Args
    }),
    {ok, _Started} = peer:call(Pid, application, ensure_all_started, [barrel_p2p]),
    put(?MODULE, [
        Pid
        | case get(?MODULE) of
            undefined -> [];
            L -> L
        end
    ]),
    {Pid, Node}.

quote(S) ->
    "\"" ++ S ++ "\"".

next_port(BasePort) ->
    Key = {?MODULE, next_port_offset},
    N =
        case get(Key) of
            undefined -> 0;
            X -> X
        end,
    put(Key, N + 1),
    BasePort + N.

wait_until(Fun, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Fun, Deadline).

wait_loop(Fun, Deadline) ->
    case
        (try
            Fun()
        catch
            _:_ -> false
        end)
    of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ?assert(false, "wait_until timed out");
                false ->
                    timer:sleep(200),
                    wait_loop(Fun, Deadline)
            end
    end.
