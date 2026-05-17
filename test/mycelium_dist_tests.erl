%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% EUnit tests for mycelium_dist boot-time validation.

-module(mycelium_dist_tests).

-include_lib("eunit/include/eunit.hrl").

project_defaults_accepts_default_callback_test() ->
    %% Fresh env: nothing in quic.dist. project_defaults/0 fills in
    %% mycelium_dist_auth_callback and the validator is happy.
    application:set_env(quic, dist, []),
    application:set_env(mycelium, auth_enabled, true),
    ?assertEqual(ok, mycelium_dist:project_defaults()),
    cleanup().

project_defaults_refuses_undefined_callback_when_enabled_test() ->
    %% User config explicitly stubs out the callback while auth is
    %% on. project_defaults/0 must crash loudly rather than ship an
    %% unauthenticated cluster silently.
    application:set_env(quic, dist, [{auth_callback, undefined}]),
    application:set_env(mycelium, auth_enabled, true),
    ?assertError(
        {mycelium_dist, auth_enabled_without_callback},
        mycelium_dist:project_defaults()
    ),
    cleanup().

project_defaults_allows_undefined_callback_when_disabled_test() ->
    %% With auth disabled, a missing callback is allowed (cookie-only
    %% mode is the operator's documented escape hatch).
    application:set_env(quic, dist, [{auth_callback, undefined}]),
    application:set_env(mycelium, auth_enabled, false),
    ?assertEqual(ok, mycelium_dist:project_defaults()),
    cleanup().

cleanup() ->
    application:unset_env(quic, dist),
    application:unset_env(mycelium, auth_enabled),
    ok.
