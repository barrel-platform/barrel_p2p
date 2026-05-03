%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% EUnit tests for mycelium_circuit_proto (v2 frames).

-module(mycelium_circuit_proto_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

cid() -> mycelium_circuit_proto:circuit_id().

%%====================================================================
%% CREATE
%%====================================================================

create_roundtrip_empty_path_test() ->
    Id = cid(),
    Bin = mycelium_circuit_proto:encode_create(Id, 'init@host', []),
    ?assertMatch({ok, {create, Id, 'init@host', []}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

create_roundtrip_two_hops_test() ->
    Id = cid(),
    Bin = mycelium_circuit_proto:encode_create(Id, 'i@a', ['hop@b', 'dst@c']),
    ?assertMatch({ok, {create, Id, 'i@a', ['hop@b', 'dst@c']}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

create_trailing_bytes_test() ->
    Id = cid(),
    Frame = mycelium_circuit_proto:encode_create(Id, 'i@a', ['d@b']),
    ?assertMatch({ok, {create, Id, 'i@a', ['d@b']}, <<"trailing-app-data">>},
                 mycelium_circuit_proto:try_decode(
                     <<Frame/binary, "trailing-app-data">>)).

create_incomplete_returns_more_test() ->
    Id = cid(),
    Frame = mycelium_circuit_proto:encode_create(Id, 'i@a', ['d@b']),
    Half = binary:part(Frame, 0, byte_size(Frame) div 2),
    ?assertMatch({more, _}, mycelium_circuit_proto:try_decode(Half)).

%%====================================================================
%% RESUME
%%====================================================================

resume_roundtrip_test() ->
    Id = cid(),
    Bin = mycelium_circuit_proto:encode_resume(Id, 12345, ['hop@b', 'dst@c']),
    ?assertMatch({ok, {resume, Id, 12345, ['hop@b', 'dst@c']}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

resume_with_empty_path_test() ->
    %% Destination -> initiator handshake leg has Path=[].
    Id = cid(),
    Bin = mycelium_circuit_proto:encode_resume(Id, 999, []),
    ?assertMatch({ok, {resume, Id, 999, []}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

resume_zero_seq_test() ->
    Id = cid(),
    Bin = mycelium_circuit_proto:encode_resume(Id, 0, ['x@y']),
    ?assertMatch({ok, {resume, Id, 0, ['x@y']}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

resume_large_seq_test() ->
    Id = cid(),
    %% Near 48-bit upper bound.
    Big = 16#FFFFFFFFFFFE,
    Bin = mycelium_circuit_proto:encode_resume(Id, Big, []),
    ?assertMatch({ok, {resume, Id, Big, []}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

%%====================================================================
%% DATA
%%====================================================================

data_roundtrip_small_test() ->
    Bin = iolist_to_binary(mycelium_circuit_proto:encode_data(7, <<"hello">>)),
    ?assertMatch({ok, {data, 7, <<"hello">>}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

data_roundtrip_empty_payload_test() ->
    Bin = iolist_to_binary(mycelium_circuit_proto:encode_data(0, <<>>)),
    ?assertMatch({ok, {data, 0, <<>>}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

data_iodata_input_test() ->
    %% encode_data accepts iodata; verify both directions.
    IO = [<<"abc">>, [<<"def">>, "ghi"]],
    Bin = iolist_to_binary(mycelium_circuit_proto:encode_data(1, IO)),
    ?assertMatch({ok, {data, 1, <<"abcdefghi">>}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

data_partial_payload_returns_more_test() ->
    Frame = iolist_to_binary(
              mycelium_circuit_proto:encode_data(3, <<"hello world">>)),
    Half = binary:part(Frame, 0, byte_size(Frame) - 4),
    ?assertMatch({more, 4}, mycelium_circuit_proto:try_decode(Half)).

%%====================================================================
%% ACK
%%====================================================================

ack_roundtrip_test() ->
    Bin = mycelium_circuit_proto:encode_ack(42),
    ?assertMatch({ok, {ack, 42}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

ack_zero_test() ->
    Bin = mycelium_circuit_proto:encode_ack(0),
    ?assertMatch({ok, {ack, 0}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

%%====================================================================
%% FIN
%%====================================================================

fin_roundtrip_test() ->
    Bin = mycelium_circuit_proto:encode_fin(99),
    ?assertMatch({ok, {fin, 99}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

%%====================================================================
%% Mixed buffer (multi-frame decode)
%%====================================================================

multi_frame_buffer_test() ->
    Id = cid(),
    Buf =
        iolist_to_binary([
            mycelium_circuit_proto:encode_create(Id, 'i@a', ['d@b']),
            mycelium_circuit_proto:encode_data(0, <<"hi">>),
            mycelium_circuit_proto:encode_data(1, <<"there">>),
            mycelium_circuit_proto:encode_ack(0),
            mycelium_circuit_proto:encode_fin(2)
        ]),
    {Frames, <<>>} = drain(Buf, []),
    ?assertEqual([
        {create, Id, 'i@a', ['d@b']},
        {data, 0, <<"hi">>},
        {data, 1, <<"there">>},
        {ack, 0},
        {fin, 2}
    ], Frames).

drain(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
drain(Buf, Acc) ->
    case mycelium_circuit_proto:try_decode(Buf) of
        {ok, Frame, Rest} -> drain(Rest, [Frame | Acc]);
        {more, _}         -> {lists:reverse(Acc), Buf};
        {error, R}        -> erlang:error({decode_error, R, Buf, Acc})
    end.

%%====================================================================
%% Errors
%%====================================================================

bad_frame_tag_test() ->
    ?assertMatch({error, {bad_frame_tag, 99}},
                 mycelium_circuit_proto:try_decode(<<99:8, 0:48>>)).

empty_buffer_returns_more_test() ->
    ?assertMatch({more, _},
                 mycelium_circuit_proto:try_decode(<<>>)).

%%====================================================================
%% Identity
%%====================================================================

circuit_id_is_16_bytes_test() ->
    ?assertEqual(16, byte_size(mycelium_circuit_proto:circuit_id())).

distinct_ids_test() ->
    ?assertNotEqual(mycelium_circuit_proto:circuit_id(),
                    mycelium_circuit_proto:circuit_id()).
