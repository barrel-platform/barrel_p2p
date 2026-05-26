%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_sync_bench).

%% Benchmark module for registry sync performance
%% Run with: rebar3 as test shell, then barrel_p2p_sync_bench:run().

-export([run/0, run/1]).
-export([bench_broadcast/1, bench_registration/1, bench_events/1]).

-define(DEFAULT_ITERATIONS, 1000).

%%====================================================================
%% API
%%====================================================================

run() ->
    run(#{iterations => ?DEFAULT_ITERATIONS}).

run(Opts) ->
    io:format("~n=== Barrel P2P Sync Benchmark ===~n~n"),

    %% Ensure application is started
    {ok, _} = application:ensure_all_started(barrel_p2p),

    Iterations = maps:get(iterations, Opts, ?DEFAULT_ITERATIONS),

    Results = [
        {registration, bench_registration(Iterations)},
        {events, bench_events(Iterations)},
        {broadcast, bench_broadcast(Iterations)}
    ],

    io:format("~n=== Summary ===~n"),
    lists:foreach(
        fun({Name, {Total, PerOp}}) ->
            io:format(
                "~-20s: ~8.2f ms total, ~8.2f us/op~n",
                [Name, Total / 1000, PerOp]
            )
        end,
        Results
    ),

    application:stop(barrel_p2p),
    Results.

%%====================================================================
%% Benchmarks
%%====================================================================

%% Benchmark service registration/unregistration
bench_registration(Iterations) ->
    io:format("Benchmarking registration (~p iterations)...~n", [Iterations]),

    {Time, _} = timer:tc(fun() ->
        lists:foreach(
            fun(I) ->
                Name = list_to_atom("bench_svc_" ++ integer_to_list(I)),
                ok = barrel_p2p:register_service(Name),
                ok = barrel_p2p:unregister_service(Name)
            end,
            lists:seq(1, Iterations)
        )
    end),

    %% 2 ops per iteration
    PerOp = Time / (Iterations * 2),
    io:format("  Registration: ~.2f ms total, ~.2f us/op~n", [Time / 1000, PerOp]),
    {Time, PerOp}.

%% Benchmark event delivery
bench_events(Iterations) ->
    io:format("Benchmarking event delivery (~p iterations)...~n", [Iterations]),

    %% Subscribe
    ok = barrel_p2p:subscribe_services(),

    {Time, _} = timer:tc(fun() ->
        lists:foreach(
            fun(I) ->
                Name = list_to_atom("event_svc_" ++ integer_to_list(I)),
                ok = barrel_p2p:register_service(Name),
                receive
                    {barrel_p2p_service_event, {service_registered, Name, _}} -> ok
                after 1000 ->
                    error({timeout, Name})
                end,
                ok = barrel_p2p:unregister_service(Name),
                receive
                    {barrel_p2p_service_event, {service_unregistered, Name, _}} -> ok
                after 1000 ->
                    error({timeout_unreg, Name})
                end
            end,
            lists:seq(1, Iterations)
        )
    end),

    ok = barrel_p2p:unsubscribe_services(self()),

    PerOp = Time / (Iterations * 2),
    io:format("  Events: ~.2f ms total, ~.2f us/op~n", [Time / 1000, PerOp]),
    {Time, PerOp}.

%% Benchmark broadcast (simulated peer sync)
bench_broadcast(Iterations) ->
    io:format("Benchmarking broadcast (~p iterations)...~n", [Iterations]),

    %% Register some services to broadcast
    lists:foreach(
        fun(I) ->
            Name = list_to_atom("broadcast_svc_" ++ integer_to_list(I)),
            barrel_p2p:register_service(Name)
        end,
        lists:seq(1, 10)
    ),

    {Time, _} = timer:tc(fun() ->
        lists:foreach(
            fun(I) ->
                Name = list_to_atom("broadcast_test_" ++ integer_to_list(I)),
                %% This triggers broadcast_update internally
                ok = barrel_p2p:register_service(Name),
                ok = barrel_p2p:unregister_service(Name)
            end,
            lists:seq(1, Iterations)
        )
    end),

    %% Cleanup
    lists:foreach(
        fun(I) ->
            Name = list_to_atom("broadcast_svc_" ++ integer_to_list(I)),
            barrel_p2p:unregister_service(Name)
        end,
        lists:seq(1, 10)
    ),

    PerOp = Time / (Iterations * 2),
    io:format("  Broadcast: ~.2f ms total, ~.2f us/op~n", [Time / 1000, PerOp]),
    {Time, PerOp}.
