%%% -*- erlang -*-
%%%
%%% EUnit tests for mycelium_dist_keys:fingerprint/1.
%%%
%%% The gen_server-backed store/lookup paths are covered by
%%% mycelium_dist_auth_SUITE; this module just locks down the pure
%%% fingerprint helper.

-module(mycelium_dist_keys_tests).

-include_lib("eunit/include/eunit.hrl").

fingerprint_returns_32_bytes_test() ->
    Fp = mycelium_dist_keys:fingerprint(<<0:256>>),
    ?assertEqual(32, byte_size(Fp)).

fingerprint_distinguishes_keys_test() ->
    Fp1 = mycelium_dist_keys:fingerprint(<<0:256>>),
    Fp2 = mycelium_dist_keys:fingerprint(<<1, 0:248>>),
    ?assertNotEqual(Fp1, Fp2).

fingerprint_rejects_short_input_test() ->
    ?assertError(function_clause,
                 mycelium_dist_keys:fingerprint(<<0, 0, 0>>)).
