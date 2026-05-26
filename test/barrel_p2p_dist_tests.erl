%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% EUnit tests for barrel_p2p_dist boot-time validation.

-module(barrel_p2p_dist_tests).

-include_lib("eunit/include/eunit.hrl").

project_defaults_accepts_default_callback_test() ->
    %% Fresh env: nothing in quic.dist. project_defaults/0 fills in
    %% barrel_p2p_dist_auth_callback and the validator is happy.
    application:set_env(quic, dist, []),
    application:set_env(barrel_p2p, auth_enabled, true),
    ?assertEqual(ok, barrel_p2p_dist:project_defaults()),
    cleanup().

project_defaults_refuses_undefined_callback_when_enabled_test() ->
    %% User config explicitly stubs out the callback while auth is
    %% on. project_defaults/0 must crash loudly rather than ship an
    %% unauthenticated cluster silently.
    application:set_env(quic, dist, [{auth_callback, undefined}]),
    application:set_env(barrel_p2p, auth_enabled, true),
    ?assertError(
        {barrel_p2p_dist, auth_enabled_without_callback},
        barrel_p2p_dist:project_defaults()
    ),
    cleanup().

project_defaults_allows_undefined_callback_when_disabled_test() ->
    %% With auth disabled, a missing callback is allowed (cookie-only
    %% mode is the operator's documented escape hatch).
    application:set_env(quic, dist, [{auth_callback, undefined}]),
    application:set_env(barrel_p2p, auth_enabled, false),
    ?assertEqual(ok, barrel_p2p_dist:project_defaults()),
    cleanup().

%% listen/2 must propagate cert-ensure errors rather than swallow
%% them and let quic_dist fail later with the indirect
%% {credentials, no_credentials}.
listen_propagates_cert_ensure_failure_test_() ->
    {setup,
        fun() ->
            meck:new(barrel_p2p_quic_cert, [passthrough]),
            meck:expect(
                barrel_p2p_quic_cert,
                ensure_cert,
                fun(_) -> {error, key_generation_failed} end
            ),
            ok
        end,
        fun(_) ->
            meck:unload(barrel_p2p_quic_cert),
            cleanup()
        end,
        fun(_) ->
            [
                ?_assertEqual(
                    {error, {cert_ensure_failed, key_generation_failed}},
                    barrel_p2p_dist:listen('node@host', #{})
                )
            ]
        end}.

%% listen_port/0 reports the configured {quic, dist_port}, and
%% undefined when it has not been resolved yet.
listen_port_reports_quic_dist_port_test() ->
    Saved = application:get_env(quic, dist_port),
    try
        application:set_env(quic, dist_port, 47123),
        ?assertEqual({ok, 47123}, barrel_p2p_dist:listen_port()),
        application:unset_env(quic, dist_port),
        ?assertEqual(undefined, barrel_p2p_dist:listen_port())
    after
        case Saved of
            {ok, V} -> application:set_env(quic, dist_port, V);
            undefined -> application:unset_env(quic, dist_port)
        end
    end.

cleanup() ->
    application:unset_env(quic, dist),
    application:unset_env(barrel_p2p, auth_enabled),
    ok.
