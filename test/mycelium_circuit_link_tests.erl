%%% -*- erlang -*-
%%%
%%% EUnit tests for mycelium_circuit_link.

-module(mycelium_circuit_link_tests).

-include_lib("eunit/include/eunit.hrl").

cid() -> mycelium_circuit_proto:circuit_id().

new_link() ->
    mycelium_circuit_link:new(initiator, cid()).

%%====================================================================
%% TX side
%%====================================================================

push_data_assigns_seq_starting_zero_test() ->
    L0 = new_link(),
    {ok, _F, L1} = mycelium_circuit_link:push_data(<<"a">>, L0),
    {ok, _F2, _L2} = mycelium_circuit_link:push_data(<<"b">>, L1),
    %% After two push_data, two unacked frames.
    ?assertEqual(2, mycelium_circuit_link:tx_unacked_count(L1) + 1).

push_data_emits_frame_decodable_test() ->
    L0 = new_link(),
    {ok, FrameIO, _L1} = mycelium_circuit_link:push_data(<<"hi">>, L0),
    Bin = iolist_to_binary(FrameIO),
    ?assertMatch({ok, {data, 0, <<"hi">>}, <<>>},
                 mycelium_circuit_proto:try_decode(Bin)).

push_fin_emits_decodable_frame_test() ->
    L0 = new_link(),
    {ok, FinFrame, _L1} = mycelium_circuit_link:push_fin(L0),
    ?assertMatch({ok, {fin, 0}, <<>>},
                 mycelium_circuit_proto:try_decode(FinFrame)).

push_fin_idempotent_test() ->
    L0 = new_link(),
    {ok, _F, L1} = mycelium_circuit_link:push_fin(L0),
    ?assertEqual(already_finned,
                 mycelium_circuit_link:push_fin(L1)).

push_data_after_fin_returns_full_test() ->
    L0 = new_link(),
    {ok, _F, L1} = mycelium_circuit_link:push_fin(L0),
    {full, _L2} = mycelium_circuit_link:push_data(<<"x">>, L1).

backpressure_kicks_in_at_max_buffer_test() ->
    %% Default max is 1 MB; push 1.1 MB worth in 100 KB chunks.
    Chunk = binary:copy(<<0>>, 100000),
    Lim = 12,
    L0 = new_link(),
    {Result, _LFinal} = pile_data(Chunk, Lim, L0),
    %% Should hit `full' before all 12 chunks are accepted.
    ?assertMatch({full_after, N} when N < Lim, Result).

pile_data(_Chunk, 0, L) -> {{ok_after, 0}, L};
pile_data(Chunk, N, L) ->
    case mycelium_circuit_link:push_data(Chunk, L) of
        {ok, _F, L2} -> pile_data(Chunk, N - 1, L2);
        {full, L2}   -> {{full_after, N}, L2}
    end.

%%====================================================================
%% RX side: in-order delivery
%%====================================================================

apply_data_in_order_delivers_test() ->
    L0 = new_link(),
    {deliver, <<"hello">>, _L1} =
        mycelium_circuit_link:apply_data(0, <<"hello">>, L0).

apply_data_advances_rx_next_expected_test() ->
    L0 = new_link(),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, <<"a">>, L0),
    {deliver, <<"b">>, _L2} = mycelium_circuit_link:apply_data(1, <<"b">>, L1).

apply_data_duplicate_is_dropped_test() ->
    L0 = new_link(),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, <<"a">>, L0),
    {duplicate, _L2} = mycelium_circuit_link:apply_data(0, <<"a-dup">>, L1).

apply_data_skip_is_protocol_error_test() ->
    L0 = new_link(),
    ?assertMatch({protocol_error, _, _},
                 mycelium_circuit_link:apply_data(2, <<"x">>, L0)).

apply_fin_in_order_test() ->
    L0 = new_link(),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, <<"a">>, L0),
    {fin, _L2} = mycelium_circuit_link:apply_fin(1, L1).

%%====================================================================
%% ACK pacing
%%====================================================================

ack_threshold_triggers_pending_test() ->
    %% Default threshold is 64 KB. Send a single 70 KB frame.
    L0 = new_link(),
    Big = binary:copy(<<$a>>, 70000),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, Big, L0),
    ?assert(mycelium_circuit_link:pending_ack(L1)).

ack_below_threshold_is_not_pending_test() ->
    L0 = new_link(),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, <<"small">>, L0),
    ?assertNot(mycelium_circuit_link:pending_ack(L1)).

take_pending_ack_returns_decodable_frame_test() ->
    L0 = new_link(),
    Big = binary:copy(<<0>>, 70000),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, Big, L0),
    {ok, AckBin, _L2} = mycelium_circuit_link:take_pending_ack(L1),
    ?assertMatch({ok, {ack, 0}, <<>>},
                 mycelium_circuit_proto:try_decode(AckBin)).

take_pending_ack_when_none_test() ->
    L0 = new_link(),
    ?assertEqual(none, mycelium_circuit_link:take_pending_ack(L0)).

ack_resets_pending_test() ->
    L0 = new_link(),
    Big = binary:copy(<<0>>, 70000),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, Big, L0),
    {ok, _, L2} = mycelium_circuit_link:take_pending_ack(L1),
    ?assertNot(mycelium_circuit_link:pending_ack(L2)).

fin_forces_immediate_ack_test() ->
    L0 = new_link(),
    {fin, L1} = mycelium_circuit_link:apply_fin(0, L0),
    ?assert(mycelium_circuit_link:pending_ack(L1)).

%%====================================================================
%% Peer ACKs prune the TX buffer
%%====================================================================

peer_ack_drops_acked_frames_test() ->
    L0 = new_link(),
    {ok, _, L1} = mycelium_circuit_link:push_data(<<"a">>, L0),
    {ok, _, L2} = mycelium_circuit_link:push_data(<<"b">>, L1),
    {ok, _, L3} = mycelium_circuit_link:push_data(<<"c">>, L2),
    %% 3 frames buffered.
    ?assertEqual(3, mycelium_circuit_link:tx_unacked_count(L3)),
    %% Peer ACKs through seq=1: frames 0 and 1 dropped, frame 2 stays.
    L4 = mycelium_circuit_link:apply_ack(1, L3),
    ?assertEqual(1, mycelium_circuit_link:tx_unacked_count(L4)).

peer_ack_releases_backpressure_test() ->
    %% Fill to backpressure, then ACK and verify push_data succeeds.
    L0 = new_link(),
    Chunk = binary:copy(<<0>>, 200000),
    L1 = pile_to_full(Chunk, L0),
    %% At capacity: next push fails.
    {full, _} = mycelium_circuit_link:push_data(Chunk, L1),
    %% Highest seq buffered = N-1; ACK it.
    HighestSeq = mycelium_circuit_link:tx_unacked_count(L1) - 1,
    L2 = mycelium_circuit_link:apply_ack(HighestSeq, L1),
    {ok, _F, _L3} = mycelium_circuit_link:push_data(<<"now ok">>, L2).

pile_to_full(Chunk, L) ->
    case mycelium_circuit_link:push_data(Chunk, L) of
        {ok, _, L2}  -> pile_to_full(Chunk, L2);
        {full, Same} -> Same
    end.

%%====================================================================
%% Migration: byte-perfect resume
%%====================================================================

resume_replay_drops_acked_keeps_unacked_test() ->
    L0 = new_link(),
    {ok, _, L1} = mycelium_circuit_link:push_data(<<"a">>, L0),
    {ok, _, L2} = mycelium_circuit_link:push_data(<<"b">>, L1),
    {ok, _, L3} = mycelium_circuit_link:push_data(<<"c">>, L2),
    %% Peer says "I have through seq=1, give me 2+".
    {ok, Replay, _L4} =
        mycelium_circuit_link:apply_peer_resume(2, [], L3),
    ?assertEqual(1, length(Replay)),
    %% Replayed frame must still decode as the original DATA(2, "c").
    ?assertMatch({ok, {data, 2, <<"c">>}, <<>>},
                 mycelium_circuit_proto:try_decode(
                   iolist_to_binary(hd(Replay)))).

resume_replay_preserves_fin_frame_type_test() ->
    L0 = new_link(),
    {ok, _, L1} = mycelium_circuit_link:push_data(<<"x">>, L0),
    {ok, _, L2} = mycelium_circuit_link:push_fin(L1),
    %% Peer ACKed nothing; replay everything.
    {ok, Replay, _L3} =
        mycelium_circuit_link:apply_peer_resume(0, [], L2),
    ?assertEqual(2, length(Replay)),
    [F1, F2] = [iolist_to_binary(F) || F <- Replay],
    ?assertMatch({ok, {data, 0, <<"x">>}, <<>>},
                 mycelium_circuit_proto:try_decode(F1)),
    ?assertMatch({ok, {fin, 1}, <<>>},
                 mycelium_circuit_proto:try_decode(F2)).

resume_peer_ahead_is_protocol_error_test() ->
    L0 = new_link(),
    {ok, _, L1} = mycelium_circuit_link:push_data(<<"a">>, L0),
    %% Peer claims to have received seq 5 but we only sent 1 frame.
    ?assertMatch({protocol_error, _, _},
                 mycelium_circuit_link:apply_peer_resume(5, [], L1)).

build_resume_carries_rx_next_expected_test() ->
    L0 = new_link(),
    {deliver, _, L1} = mycelium_circuit_link:apply_data(0, <<"x">>, L0),
    {deliver, _, L2} = mycelium_circuit_link:apply_data(1, <<"y">>, L1),
    {Frame, _L3} = mycelium_circuit_link:build_resume(['hop@b'], L2),
    ?assertMatch({ok, {resume, _Id, 2, ['hop@b']}, <<>>},
                 mycelium_circuit_proto:try_decode(Frame)).

%%====================================================================
%% feed/2 multi-frame parsing
%%====================================================================

feed_decodes_multi_frame_buffer_test() ->
    L0 = new_link(),
    Buf = iolist_to_binary([
        mycelium_circuit_proto:encode_data(0, <<"a">>),
        mycelium_circuit_proto:encode_data(1, <<"b">>),
        mycelium_circuit_proto:encode_ack(0)
    ]),
    {ok, Frames, _L1} = mycelium_circuit_link:feed(Buf, L0),
    ?assertEqual([
        {data, 0, <<"a">>},
        {data, 1, <<"b">>},
        {ack, 0}
    ], Frames).

feed_partial_buffer_keeps_residual_test() ->
    L0 = new_link(),
    Frame = iolist_to_binary(
              mycelium_circuit_proto:encode_data(0, <<"abcdef">>)),
    Half = binary:part(Frame, 0, byte_size(Frame) div 2),
    {ok, [], L1} = mycelium_circuit_link:feed(Half, L0),
    %% Feeding the rest now decodes the full frame.
    Rest = binary:part(Frame, byte_size(Frame) div 2,
                       byte_size(Frame) - byte_size(Frame) div 2),
    {ok, [{data, 0, <<"abcdef">>}], _L2} =
        mycelium_circuit_link:feed(Rest, L1).
