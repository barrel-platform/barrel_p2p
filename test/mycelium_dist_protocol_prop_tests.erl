%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Property tests for mycelium_dist_protocol.
%%%
%%% Two flavours:
%%%
%%%   1. Round-trip: for every well-formed input to one of the
%%%      `encode_*' functions, `decode/1' returns the matching tuple.
%%%
%%%   2. Fuzz: `decode/1' never crashes on a random binary; it
%%%      always returns either a tagged success or {error, _}.

-module(mycelium_dist_protocol_prop_tests).

-include_lib("eunit/include/eunit.hrl").
%% eunit and proper both define ?LET; proper's is the one we use here.
-undef('LET').
-include_lib("proper/include/proper.hrl").

-define(NUMTESTS, 500).
-define(PUBLIC_KEY_SIZE, 32).
-define(X25519_KEY_SIZE, 32).
-define(NONCE_SIZE, 32).
-define(SIGNATURE_SIZE, 64).

prop_test_() ->
    [{timeout, 60, ?_assert(run(prop_hello_roundtrip()))},
     {timeout, 60, ?_assert(run(prop_challenge_roundtrip()))},
     {timeout, 60, ?_assert(run(prop_response_roundtrip()))},
     {timeout, 60, ?_assert(run(prop_key_exchange_roundtrip()))},
     {timeout, 60, ?_assert(run(prop_fail_roundtrip()))},
     {timeout, 60, ?_assert(run(prop_ok_roundtrip()))},
     {timeout, 60, ?_assert(run(prop_decode_random_never_crashes()))}].

run(Prop) ->
    proper:quickcheck(Prop, [{numtests, ?NUMTESTS}, {to_file, user}]).

%%====================================================================
%% Generators
%%====================================================================

fixed_bin(N) ->
    ?LET(Bytes, vector(N, choose(0, 255)),
         list_to_binary(Bytes)).

node_name() ->
    ?LET(S, non_empty(list(choose($a, $z))),
         list_to_atom(S ++ "@host")).

%%====================================================================
%% Round-trip properties
%%====================================================================

prop_hello_roundtrip() ->
    ?FORALL({Node, PubKey},
            {node_name(), fixed_bin(?PUBLIC_KEY_SIZE)},
            begin
                Enc = mycelium_dist_protocol:encode_hello(Node, PubKey),
                case mycelium_dist_protocol:decode(Enc) of
                    {hello, Node, PubKey} -> true;
                    _ -> false
                end
            end).

prop_challenge_roundtrip() ->
    ?FORALL({Nonce, TS},
            {fixed_bin(?NONCE_SIZE), choose(0, 16#FFFFFFFFFFFFFFFF)},
            begin
                Enc = mycelium_dist_protocol:encode_challenge(Nonce, TS),
                {challenge, Nonce, TS} =:= mycelium_dist_protocol:decode(Enc)
            end).

prop_response_roundtrip() ->
    ?FORALL(Sig, fixed_bin(?SIGNATURE_SIZE),
            begin
                Enc = mycelium_dist_protocol:encode_response(Sig),
                {response, Sig} =:= mycelium_dist_protocol:decode(Enc)
            end).

prop_key_exchange_roundtrip() ->
    ?FORALL(Key, fixed_bin(?X25519_KEY_SIZE),
            begin
                Enc = mycelium_dist_protocol:encode_key_exchange(Key),
                {key_exchange, Key} =:= mycelium_dist_protocol:decode(Enc)
            end).

prop_fail_roundtrip() ->
    ?FORALL(Reason, binary(),
            begin
                Enc = mycelium_dist_protocol:encode_fail(Reason),
                {fail, Reason} =:= mycelium_dist_protocol:decode(Enc)
            end).

prop_ok_roundtrip() ->
    ?FORALL(_, integer(),
            ok =:= mycelium_dist_protocol:decode(
                     mycelium_dist_protocol:encode_ok())).

%%====================================================================
%% Robustness
%%====================================================================

%% Any binary input must produce either a tagged success or
%% {error, _}. No crash, no badmatch.
prop_decode_random_never_crashes() ->
    ?FORALL(Bin, binary(),
            try mycelium_dist_protocol:decode(Bin) of
                ok                  -> true;
                {error, _}          -> true;
                {hello, _, _}       -> true;
                {challenge, _, _}   -> true;
                {response, _}       -> true;
                {key_exchange, _}   -> true;
                {fail, _}           -> true;
                _                   -> false
            catch _:_ ->
                false
            end).
