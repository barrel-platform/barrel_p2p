%%% -*- erlang -*-
%%%
%%% Multi-node CT suite for circuits v2.
%%%
%%% Topology: diamond.
%%%
%%%         N2
%%%        /  \
%%%      N1    N4
%%%        \  /
%%%         N3
%%%
%%% N1 and N4 are not in each other's active view; the only ways to
%%% reach N4 from N1 are via [N2] or [N3]. Killing one branch forces
%%% migration onto the other.
%%%
%%% The CT BEAM does not start net_kernel. Slaves run with
%%% `-proto_dist quic'; the suite drives them via `quic_call.sh'.

-module(mycelium_circuit_multinode_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    suite/0, all/0, groups/0,
    init_per_suite/1, end_per_suite/1,
    init_per_group/2, end_per_group/2,
    init_per_testcase/2, end_per_testcase/2
]).

-export([
    single_hop_roundtrip/1,
    multi_hop_roundtrip/1,
    auto_routed_roundtrip/1,
    migration_byte_perfect/1,
    app_stream_coexistence/1
]).

%% Entry points invoked on the slave BEAMs via quic_call.sh / rpc.
-export([
    run_single_hop/2,
    run_multi_hop/3,
    run_auto_routed/2,
    run_migration/3,
    run_coexistence/2,
    register_app_echo/0,
    unregister_app_echo/0
]).

-define(COOKIE, mycelium_ct_cookie).

%%====================================================================
%% CT callbacks
%%====================================================================

suite() ->
    [{timetrap, {minutes, 5}}].

all() ->
    case os:getenv("MYCELIUM_CT_QUIC_MULTINODE") of
        "1" ->
            %% Each case runs in its own group with fresh slaves to
            %% guarantee no state leakage between sequential cases.
            [{group, diamond_single},
             {group, diamond_multi},
             {group, diamond_auto},
             {group, diamond_migration},
             {group, diamond_coex}];
        _ ->
            %% Skipped by default. Opt in with
            %% MYCELIUM_CT_QUIC_MULTINODE=1.
            %%
            %% End-to-end coverage of the v2 protocol on a 4-node
            %% diamond (`-proto_dist quic') driven via upstream
            %% `quic_call.sh': single-hop, multi-hop, auto-routed,
            %% byte-perfect migration, and app-stream coexistence.
            []
    end.

groups() ->
    Cases = [
        {diamond_single, single_hop_roundtrip},
        {diamond_multi, multi_hop_roundtrip},
        {diamond_auto, auto_routed_roundtrip},
        {diamond_migration, migration_byte_perfect},
        {diamond_coex, app_stream_coexistence}
    ],
    [{G, [], [C]} || {G, C} <- Cases].

init_per_suite(Config) ->
    %% Cert dir is per-suite, shared across slaves.
    PrivDir = ?config(priv_dir, Config),
    CertDir = filename:join(PrivDir, "quic_cert"),
    Paths = mycelium_quic_test_helper:setup_cert(CertDir),
    %% Make sure quic_call.sh is reachable.
    QuicCall = mycelium_quic_test_helper:quic_call_path(),
    [{cert_paths, Paths}, {quic_call, QuicCall} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(G, Config) when G =:= diamond_single;
                              G =:= diamond_multi;
                              G =:= diamond_auto;
                              G =:= diamond_migration;
                              G =:= diamond_coex ->
    init_diamond(Config);
init_per_group(diamond, Config) ->
    init_diamond(Config);
init_per_group(_Other, Config) ->
    Config.

init_diamond(Config) ->
    PrivDir = ?config(priv_dir, Config),
    #{cert := Cert, key := Key} = ?config(cert_paths, Config),

    %% Allocate four ports starting from a strongly-randomized base
    %% to avoid collisions across consecutive `rebar3 ct' runs and
    %% with any zombie slaves still bound from a prior failure.
    BasePort = 20000 + rand:uniform(20000),

    Mk = fun(Tag, Idx) ->
        Short = mycelium_quic_test_helper:short_name(
                  list_to_atom("mycdmd_" ++ Tag)),
        Long = mycelium_quic_test_helper:long_name(Short),
        Port = BasePort + Idx,
        {Tag, Short, Long, Port}
    end,
    Slaves0 = [
        Mk("n1", 0),
        Mk("n2", 1),
        Mk("n3", 2),
        Mk("n4", 3)
    ],

    %% Static node->{host, port} map. Every slave (and the probe) uses
    %% the same map for `quic_discovery_static'.
    Nodes = [{Long, {"127.0.0.1", Port}}
             || {_, _, Long, Port} <- Slaves0],

    %% Mycelium env shared by all slaves. Auth off; small active size.
    BaseEnv = [
        {active_size, 2},
        {passive_size, 6},
        {auth_enabled, false},
        {dist_cookie, ?COOKIE}
    ],

    Started = lists:map(
        fun({Tag, Short, Long, Port}) ->
            Spec = #{
                name => Long,
                port => Port,
                cookie => ?COOKIE,
                cert => Cert,
                key => Key,
                nodes => Nodes,
                mycelium_env => BaseEnv
            },
            {ok, Slave} = mycelium_quic_test_helper:start_slave(
                            Short, PrivDir, Spec, 60000),
            {Tag, Slave, Long}
        end, Slaves0),

    %% Form the diamond: N1 ↔ {N2, N3}, N4 ↔ {N2, N3}.
    {_, S1, L1} = lists:keyfind("n1", 1, Started),
    {_, _,  L2} = lists:keyfind("n2", 1, Started),
    {_, _,  L3} = lists:keyfind("n3", 1, Started),
    {_, S4, L4} = lists:keyfind("n4", 1, Started),

    _ = join_force(S1, [L2, L3]),
    _ = join_force(S4, [L2, L3]),
    %% Brief settle so HyParView's FORWARD_JOIN propagation completes.
    timer:sleep(2000),

    Pairs = [
        {S1, [L2, L3]},
        {element(2, lists:keyfind("n2", 1, Started)), [L1, L4]},
        {element(2, lists:keyfind("n3", 1, Started)), [L1, L4]},
        {S4, [L2, L3]}
    ],
    [wait_active_view(SS, Want) || {SS, Want} <- Pairs],

    Tagged = [{list_to_atom(Tag), Slave, Long}
              || {Tag, Slave, Long} <- Started],

    [{slaves, Tagged} | Config].

end_per_group(G, Config) when G =:= diamond_single;
                             G =:= diamond_multi;
                             G =:= diamond_auto;
                             G =:= diamond_migration;
                             G =:= diamond_coex;
                             G =:= diamond ->
    Slaves = ?config(slaves, Config),
    [mycelium_quic_test_helper:stop_slave(S) || {_, S, _} <- Slaves],
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) -> Config.
end_per_testcase(_TestCase, _Config) -> ok.

%%====================================================================
%% Cases
%%====================================================================

single_hop_roundtrip(Config) ->
    {S1, _, L1} = lookup(n1, Config),
    {_, _, L2} = lookup(n2, Config),
    %% Sanity 1: N1 sees N2 in its active view.
    AV = mycelium_quic_test_helper:qcall(S1, mycelium, active_view, []),
    ?assert(lists:member(L2, AV)),
    %% Sanity 2: N1's quic_dist sees N2 connected.
    NodesOnN1 = mycelium_quic_test_helper:qcall(
        S1, erlang, nodes, []),
    ct:pal("nodes() on N1 = ~p", [NodesOnN1]),
    ?assert(lists:member(L2, NodesOnN1)),
    Result = mycelium_quic_test_helper:qcall(
        S1, ?MODULE, run_single_hop, [L1, L2], 30000),
    ?assertEqual(ok, Result).

multi_hop_roundtrip(Config) ->
    {S1, _, L1} = lookup(n1, Config),
    {_, _, L2} = lookup(n2, Config),
    {_, _, L4} = lookup(n4, Config),
    Result = mycelium_quic_test_helper:qcall(
        S1, ?MODULE, run_multi_hop, [L1, [L2], L4], 60000),
    ?assertEqual(ok, Result).

auto_routed_roundtrip(Config) ->
    {S1, _, L1} = lookup(n1, Config),
    {_, _, L4} = lookup(n4, Config),
    Result = mycelium_quic_test_helper:qcall(
        S1, ?MODULE, run_auto_routed, [L1, L4], 30000),
    ?assertEqual(ok, Result).

migration_byte_perfect(Config) ->
    {S1, _, L1} = lookup(n1, Config),
    {_, _, L2} = lookup(n2, Config),
    {_, _, L4} = lookup(n4, Config),
    Result = mycelium_quic_test_helper:qcall(
        S1, ?MODULE, run_migration, [L1, L2, L4], 60000),
    ?assertEqual(ok, Result).

app_stream_coexistence(Config) ->
    {S1, _, L1} = lookup(n1, Config),
    {_, _, L2} = lookup(n2, Config),
    Result = mycelium_quic_test_helper:qcall(
        S1, ?MODULE, run_coexistence, [L1, L2], 30000),
    ?assertEqual(ok, Result).

%%====================================================================
%% In-slave runners (called via quic_call.sh; these run on the slave
%% N1's BEAM)
%%====================================================================

%% Each runner returns 'ok' on success, fails the case otherwise.
%% They drive both endpoints by spawning a listener on the
%% destination via rpc.

run_single_hop(_N1, N2) ->
    {ok, ListenerPid} = start_listener(N2),
    {ok, CRef} = mycelium_circuit:open(N2),
    receive after 200 -> ok end,
    ok = mycelium_circuit:send(CRef, <<"ping">>),
    Result = receive
        {circuit, CRef, {data, <<"ping">>}} ->
            ok
    after 5000 ->
        {error, no_echo}
    end,
    cleanly_close(CRef),
    stop_listener(N2, ListenerPid),
    Result.

run_multi_hop(_N1, Path, N4) ->
    {ok, ListenerPid} = start_listener(N4),
    {ok, CRef} = mycelium_circuit:open(N4, Path),
    Body = crypto:strong_rand_bytes(1024),
    Hash = crypto:hash(sha256, Body),
    ok = mycelium_circuit:send(CRef, Body),
    Result = receive
        {circuit, CRef, {data, Echoed}} ->
            case crypto:hash(sha256, Echoed) of
                Hash -> ok;
                _    -> {error, hash_mismatch}
            end
    after 10000 ->
        {error, no_echo}
    end,
    cleanly_close(CRef),
    stop_listener(N4, ListenerPid),
    Result.

run_auto_routed(_N1, N4) ->
    {ok, ListenerPid} = start_listener(N4),
    {ok, CRef} = mycelium_circuit:open(N4),
    ok = mycelium_circuit:send(CRef, <<"hi">>),
    Result = receive
        {circuit, CRef, {data, <<"hi">>}} -> ok
    after 10000 ->
        {error, no_echo}
    end,
    cleanly_close(CRef),
    stop_listener(N4, ListenerPid),
    Result.

run_migration(_N1, N2, N4) ->
    {ok, ListenerPid} = start_listener(N4),
    {ok, CRef} = mycelium_circuit:open(N4, [N2]),
    %% Stream a SHA-stamped 64 KB payload in 4 KB chunks, asking N2
    %% to disconnect from N4 mid-stream. Each side echoes back the
    %% bytes it received.
    Body = crypto:strong_rand_bytes(64 * 1024),
    spawn(fun() ->
        timer:sleep(150),
        rpc:call(N2, erlang, disconnect_node, [N4])
    end),
    Sender = self(),
    spawn_link(fun() ->
        chunked_send(CRef, Body, 4096),
        ok = mycelium_circuit:close(CRef),
        Sender ! sent
    end),
    Echoed = collect_echo(CRef, byte_size(Body), <<>>),
    stop_listener(N4, ListenerPid),
    receive sent -> ok after 30000 -> ok end,
    case Echoed of
        Body -> ok;
        Other -> {error, {payload_mismatch, byte_size(Body), byte_size(Other)}}
    end.

run_coexistence(_N1, N2) ->
    %% A circuit and an app stream coexist on the same connection.
    {ok, ListenerPid} = start_listener(N2),
    %% Register an app handler on N2 first.
    rpc:call(N2, ?MODULE, register_app_echo, []),
    {ok, CRef} = mycelium_circuit:open(N2),
    {ok, SR} = mycelium_streams:open(<<"test:bench">>, N2),
    ok = mycelium_circuit:send(CRef, <<"on circuit">>),
    ok = quic_dist:send(SR, <<"on stream">>),
    receive {circuit, CRef, {data, <<"on circuit">>}} -> ok
    after 5000 -> ?assert(false) end,
    receive {quic_dist_stream, SR, {data, <<"on stream">>, _}} -> ok
    after 5000 -> ?assert(false) end,
    ok = mycelium_circuit:close(CRef),
    _ = quic_dist:close_stream(SR),
    rpc:call(N2, ?MODULE, unregister_app_echo, []),
    stop_listener(N2, ListenerPid),
    ok.

%%====================================================================
%% Helpers (run inside slaves; entry points for cross-slave RPC)
%%====================================================================

%% Start a listener on `Node' that echoes every received `data' back
%% on the same circuit, until it gets `closed'.
start_listener(Node) ->
    Self = self(),
    Pid = spawn(Node, fun() ->
        ok = mycelium_circuit:listen(),
        Self ! {listener_ready, self()},
        listener_loop()
    end),
    receive
        {listener_ready, Pid} -> {ok, Pid}
    after 5000 ->
        exit({listener_start_timeout, Node})
    end.

listener_loop() ->
    receive
        {circuit, CRef, {opened, _From}} ->
            echo_loop(CRef);
        stop ->
            ok
    end.

echo_loop(CRef) ->
    receive
        {circuit, CRef, {data, Bin}} ->
            mycelium_circuit:send(CRef, Bin),
            echo_loop(CRef);
        {circuit, CRef, closed} ->
            ok;
        {circuit, CRef, _Other} ->
            echo_loop(CRef)
    end.

stop_listener(_Node, Pid) ->
    catch (Pid ! stop),
    %% Wait briefly so the listener's exit propagates back through
    %% the destination pipe and the relay chain. Stops residual
    %% in-flight bytes from leaking onto a fresh stream during the
    %% next test case.
    timer:sleep(300),
    ok.

%% Synchronous close: send FIN and wait for the matching `closed'
%% event from the peer before continuing. Drains the owner's mailbox
%% to avoid stale `{circuit, CRef, _}' messages from earlier circuits
%% bleeding into the next test case.
cleanly_close(CRef) ->
    catch mycelium_circuit:close(CRef),
    drain_circuit_messages(CRef),
    timer:sleep(150),
    drain_circuit_messages(CRef),
    ok.

drain_circuit_messages(CRef) ->
    receive
        {circuit, CRef, _} -> drain_circuit_messages(CRef)
    after 100 -> ok
    end.

chunked_send(_CRef, <<>>, _N) ->
    ok;
chunked_send(CRef, Bin, N) when byte_size(Bin) =< N ->
    mycelium_circuit:send(CRef, Bin);
chunked_send(CRef, Bin, N) ->
    <<C:N/binary, Rest/binary>> = Bin,
    mycelium_circuit:send(CRef, C),
    chunked_send(CRef, Rest, N).

collect_echo(_CRef, 0, Acc) ->
    Acc;
collect_echo(CRef, Need, Acc) ->
    receive
        {circuit, CRef, {data, Bin}} ->
            collect_echo(CRef, max(0, Need - byte_size(Bin)),
                         <<Acc/binary, Bin/binary>>);
        {circuit, CRef, {migrating, _}} ->
            collect_echo(CRef, Need, Acc);
        {circuit, CRef, {migrated, _, _}} ->
            collect_echo(CRef, Need, Acc);
        {circuit, CRef, {migration_failed, _}} ->
            Acc;
        {circuit, CRef, closed} ->
            Acc
    after 30000 ->
        Acc
    end.

%%====================================================================
%% App-stream echo (used by run_coexistence on the destination slave)
%%====================================================================

register_app_echo() ->
    Pid = spawn(fun app_echo_loop/0),
    ok = mycelium_streams:register_acceptor(<<"test:bench">>, Pid),
    ok.

unregister_app_echo() ->
    mycelium_streams:unregister_acceptor(<<"test:bench">>).

app_echo_loop() ->
    receive
        {mstream, SR, opened, _} ->
            app_echo_stream(SR);
        stop ->
            ok
    end.

app_echo_stream(SR) ->
    receive
        {quic_dist_stream, SR, {data, Bin, _Fin}} ->
            quic_dist:send(SR, Bin),
            app_echo_stream(SR);
        {quic_dist_stream, SR, closed} ->
            ok
    end.

%%====================================================================
%% Diamond setup helpers
%%====================================================================

%% Force `Slave' to join each `Neighbour'. Doesn't fail if a join is
%% already established.
join_force(Slave, Neighbours) ->
    [{N, mycelium_quic_test_helper:qcall(Slave, mycelium, join, [N])}
     || N <- Neighbours].

wait_active_view(Slave, Want) ->
    Pred = fun() ->
        Result = mycelium_quic_test_helper:qcall(
                   Slave, mycelium, active_view, []),
        case Result of
            View when is_list(View) ->
                lists:all(fun(N) -> lists:member(N, View) end, Want);
            _ ->
                %% Transient probe failure (cookie race, etc.) — retry.
                false
        end
    end,
    case mycelium_quic_test_helper:wait_until(Pred, 30000) of
        ok      -> ok;
        timeout ->
            Last = mycelium_quic_test_helper:qcall(
                     Slave, mycelium, active_view, []),
            ct:fail({active_view_timeout, Slave, Want, last_seen, Last})
    end.

lookup(Key, Config) ->
    {Key, Slave, Long} =
        lists:keyfind(Key, 1, ?config(slaves, Config)),
    {Slave, Slave, Long}.
