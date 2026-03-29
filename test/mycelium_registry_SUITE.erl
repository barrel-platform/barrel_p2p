-module(mycelium_registry_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    test_register_service/1,
    test_register_duplicate/1,
    test_unregister_service/1,
    test_lookup_local/1,
    test_lookup_not_found/1,
    test_list_services/1,
    test_service_monitor/1,
    test_whereis_service_local/1,
    test_whereis_service_retry_not_found/1,
    test_whereis_service_no_retry_on_success/1,
    test_whereis_service_custom_retries/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, registry}].

groups() ->
    [
        {registry, [sequence], [
            test_register_service,
            test_register_duplicate,
            test_unregister_service,
            test_lookup_local,
            test_lookup_not_found,
            test_list_services,
            test_service_monitor,
            test_whereis_service_local,
            test_whereis_service_retry_not_found,
            test_whereis_service_no_retry_on_success,
            test_whereis_service_custom_retries
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    {ok, _} = application:ensure_all_started(mycelium),
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:stop(mycelium),
    ok.

%%====================================================================
%% Test Cases
%%====================================================================

test_register_service(_Config) ->
    ?assertEqual(ok, mycelium:register_service(test_svc, #{type => worker})),
    ok.

test_register_duplicate(_Config) ->
    ok = mycelium:register_service(dup_svc),
    ?assertEqual({error, already_registered}, mycelium:register_service(dup_svc)),
    ok.

test_unregister_service(_Config) ->
    ok = mycelium:register_service(unreg_svc),
    ok = mycelium:unregister_service(unreg_svc),
    ?assertEqual({error, not_found}, mycelium:lookup_local(unreg_svc)),
    ok.

test_lookup_local(_Config) ->
    ok = mycelium:register_service(local_svc),
    {ok, Pid} = mycelium:lookup_local(local_svc),
    ?assertEqual(self(), Pid),
    ok.

test_lookup_not_found(_Config) ->
    ?assertEqual({error, not_found}, mycelium:lookup(nonexistent)),
    ?assertEqual({error, not_found}, mycelium:lookup_local(nonexistent)),
    ok.

test_list_services(_Config) ->
    ok = mycelium:register_service(svc_a),
    ok = mycelium:register_service(svc_b),
    Services = mycelium:list_services(),
    ?assert(lists:member(svc_a, Services)),
    ?assert(lists:member(svc_b, Services)),
    ok.

test_service_monitor(_Config) ->
    %% Spawn a process that registers a service then dies
    Parent = self(),
    Pid = spawn(fun() ->
        ok = mycelium:register_service(monitored_svc),
        Parent ! registered,
        receive stop -> ok end
    end),
    receive registered -> ok end,

    %% Service should exist
    {ok, Pid} = mycelium:lookup_local(monitored_svc),

    %% Kill the process
    Pid ! stop,
    timer:sleep(100),

    %% Service should be gone
    ?assertEqual({error, not_found}, mycelium:lookup_local(monitored_svc)),
    ok.

test_whereis_service_local(_Config) ->
    %% Test whereis_service finds local services
    ok = mycelium:register_service(whereis_local_svc),
    {ok, Pid} = mycelium:whereis_service(whereis_local_svc),
    ?assertEqual(self(), Pid),
    ok = mycelium:unregister_service(whereis_local_svc),
    ok.

test_whereis_service_retry_not_found(_Config) ->
    %% Test that whereis_service retries on not_found
    %% With 0 retries, should return immediately
    Start = erlang:monotonic_time(millisecond),
    ?assertEqual({error, not_found}, mycelium:whereis_service(nonexistent_svc, #{retries => 0})),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% Should complete quickly with 0 retries
    ?assert(Elapsed < 50),
    ok.

test_whereis_service_no_retry_on_success(_Config) ->
    %% Test that whereis_service doesn't retry when found
    ok = mycelium:register_service(success_svc),

    Start = erlang:monotonic_time(millisecond),
    {ok, _Pid} = mycelium:whereis_service(success_svc),
    Elapsed = erlang:monotonic_time(millisecond) - Start,

    %% Should return immediately without any retry delay
    ?assert(Elapsed < 50),

    ok = mycelium:unregister_service(success_svc),
    ok.

test_whereis_service_custom_retries(_Config) ->
    %% Test that retry count can be customized
    %% With 1 retry and ~100ms base backoff, should take at least 100ms
    Start = erlang:monotonic_time(millisecond),
    ?assertEqual({error, not_found}, mycelium:whereis_service(custom_retry_svc, #{retries => 1})),
    Elapsed = erlang:monotonic_time(millisecond) - Start,

    %% Should have waited for at least one backoff cycle (100ms base + jitter)
    ?assert(Elapsed >= 100),
    %% But not too long
    ?assert(Elapsed < 500),
    ok.
