-module(mycelium_hyparview_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    test_initial_state/1,
    test_active_view_empty/1,
    test_passive_view_empty/1,
    test_leave_clears_views/1,
    test_event_subscription/1,
    test_shuffle_no_peers/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, unit}].

groups() ->
    [
        {unit, [sequence], [
            test_initial_state,
            test_active_view_empty,
            test_passive_view_empty,
            test_leave_clears_views,
            test_event_subscription,
            test_shuffle_no_peers
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

test_initial_state(_Config) ->
    %% Verify dist_auto_connect was set
    ?assertEqual({ok, never}, application:get_env(kernel, dist_auto_connect)),
    ok.

test_active_view_empty(_Config) ->
    ?assertEqual([], mycelium:active_view()),
    ok.

test_passive_view_empty(_Config) ->
    ?assertEqual([], mycelium:passive_view()),
    ok.

test_leave_clears_views(_Config) ->
    mycelium:leave(),
    ?assertEqual([], mycelium:active_view()),
    ?assertEqual([], mycelium:passive_view()),
    ok.

test_event_subscription(_Config) ->
    ok = mycelium:subscribe(),
    %% No events in isolation
    receive
        {mycelium_event, _Event} ->
            ct:fail(unexpected_event)
    after 100 ->
        ok
    end,
    ok = mycelium:unsubscribe(self()),
    ok.

test_shuffle_no_peers(_Config) ->
    %% Should not crash with no peers
    mycelium_hyparview_shuffle:trigger_shuffle(),
    timer:sleep(50),
    ok.
