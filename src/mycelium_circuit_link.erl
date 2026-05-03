%%% -*- erlang -*-
%%%
%%% Mycelium Circuit Reliable Link
%%%
%%% Pure-data state for one direction of a reliable circuit
%%% endpoint. Holds:
%%%
%%%   - TX: the next sequence number, the buffer of unacked frames,
%%%     and buffered byte counts for backpressure.
%%%   - RX: the next expected sequence, parse buffer for incoming
%%%     QUIC stream bytes, and ack-pacing counters.
%%%
%%% Has no awareness of QUIC streams or processes; the calling pipe
%%% drives it with helper calls and emits the returned frames. This
%%% lets the protocol be unit-tested without a network.
%%%
%%% Wire format is defined in `mycelium_circuit_proto'. Both DATA
%%% and FIN consume one sequence number; ACKs are cumulative and
%%% cover any frame type with `Seq <= CumulativeSeq'.
%%%
%%% Migration: the calling pipe drives the symmetric RESUME exchange
%%% via `pending_resume/3' and `apply_peer_resume/3'. After both
%%% sides have exchanged RESUMEs, neither loses any frame.
%%%
%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_circuit_link).

-export([
    new/2,
    circuit_id/1,
    %% TX
    push_data/2,
    push_fin/1,
    tx_unacked_count/1,
    tx_unacked_bytes/1,
    tx_full/1,
    %% RX
    feed/2,
    apply_data/3,
    apply_fin/2,
    apply_ack/2,
    apply_peer_resume/3,
    %% ACK pacing
    pending_ack/1,
    take_pending_ack/1,
    %% Migration
    build_resume/2,
    pending_resume_replay/2
]).

-export_type([link_state/0, action/0]).

-record(link, {
    role :: initiator | destination,
    circuit_id :: binary(),

    %% TX side
    tx_next_seq = 0 :: non_neg_integer(),
    tx_unacked = queue:new() :: queue:queue({Seq :: non_neg_integer(),
                                             Bytes :: non_neg_integer(),
                                             Frame :: binary()}),
    tx_unacked_bytes = 0 :: non_neg_integer(),
    tx_max_buffer = 1048576 :: pos_integer(),
    fin_sent = false :: boolean(),

    %% RX side
    rx_next_expected = 0 :: non_neg_integer(),
    rx_buffer = <<>> :: binary(),
    rx_pending_ack_bytes = 0 :: non_neg_integer(),
    rx_pending_ack_seq = none :: none | non_neg_integer(),
    rx_seen_fin = false :: boolean(),

    %% Tunables
    ack_byte_threshold = 65536 :: pos_integer()
}).

-opaque link_state() :: #link{}.

-type action() ::
        {deliver, binary()}
      | fin
      | duplicate
      | {protocol_error, term()}.

%%====================================================================
%% Construction
%%====================================================================

-spec new(initiator | destination, binary()) -> link_state().
new(Role, CircuitId) when Role =:= initiator orelse Role =:= destination ->
    #link{role = Role, circuit_id = CircuitId}.

-spec circuit_id(link_state()) -> binary().
circuit_id(#link{circuit_id = Id}) -> Id.

%%====================================================================
%% TX side
%%====================================================================

%% @doc Frame `Data' as `FRAME_DATA(Seq, Data)', enqueue it for
%% retransmit, and return the encoded frame for the caller to send.
%% Returns `{full, Link}' if the unacked buffer is full -- caller
%% must wait or back off; no frame is generated, no seq consumed.
-spec push_data(iodata(), link_state()) ->
    {ok, Frame :: iodata(), link_state()} | {full, link_state()}.
push_data(_Data, #link{fin_sent = true} = L) ->
    {full, L};
push_data(_Data, L = #link{tx_unacked_bytes = U, tx_max_buffer = M})
  when U >= M ->
    {full, L};
push_data(Data, L = #link{tx_next_seq = Seq,
                          tx_unacked = Q,
                          tx_unacked_bytes = U}) ->
    Bin = iolist_to_binary(Data),
    Frame = mycelium_circuit_proto:encode_data(Seq, Bin),
    Sz = byte_size(Bin),
    Q2 = queue:in({Seq, Sz, Frame}, Q),
    {ok, Frame, L#link{tx_next_seq = Seq + 1,
                       tx_unacked = Q2,
                       tx_unacked_bytes = U + Sz}}.

%% @doc Append a `FRAME_FIN(Seq)' to the TX queue. Idempotent.
-spec push_fin(link_state()) ->
    {ok, Frame :: binary(), link_state()} | already_finned.
push_fin(#link{fin_sent = true}) ->
    already_finned;
push_fin(L = #link{tx_next_seq = Seq, tx_unacked = Q}) ->
    Frame = mycelium_circuit_proto:encode_fin(Seq),
    Q2 = queue:in({Seq, 0, Frame}, Q),
    {ok, Frame, L#link{tx_next_seq = Seq + 1, tx_unacked = Q2,
                       fin_sent = true}}.

-spec tx_unacked_count(link_state()) -> non_neg_integer().
tx_unacked_count(#link{tx_unacked = Q}) -> queue:len(Q).

-spec tx_unacked_bytes(link_state()) -> non_neg_integer().
tx_unacked_bytes(#link{tx_unacked_bytes = N}) -> N.

-spec tx_full(link_state()) -> boolean().
tx_full(#link{tx_unacked_bytes = U, tx_max_buffer = M}) -> U >= M.

%%====================================================================
%% RX side
%%====================================================================

%% @doc Append `Bytes' to the receive buffer and try to decode every
%% frame currently complete. Returns the list of decoded frames and a
%% new link state with the residual buffer.
-spec feed(binary(), link_state()) ->
    {ok, [mycelium_circuit_proto:frame()], link_state()}
  | {error, term(), link_state()}.
feed(Bytes, L = #link{rx_buffer = Buf}) ->
    pull_frames(<<Buf/binary, Bytes/binary>>, [], L).

pull_frames(Buf, Acc, L) ->
    case mycelium_circuit_proto:try_decode(Buf) of
        {ok, Frame, Rest} ->
            pull_frames(Rest, [Frame | Acc], L);
        {more, _} ->
            {ok, lists:reverse(Acc), L#link{rx_buffer = Buf}};
        {error, Reason} ->
            {error, Reason, L#link{rx_buffer = Buf}}
    end.

%% @doc Apply a peer DATA frame. Returns one of:
%%   - `{deliver, Payload, Link}' when Seq matches `rx_next_expected'.
%%   - `{duplicate, Link}' when Seq < `rx_next_expected' (already
%%     delivered before a migration; silently drop).
%%   - `{protocol_error, Reason, Link}' when Seq > `rx_next_expected'
%%     (sender skipped a frame; bail).
-spec apply_data(non_neg_integer(), binary(), link_state()) ->
    {deliver, binary(), link_state()}
  | {duplicate, link_state()}
  | {protocol_error, term(), link_state()}.
apply_data(Seq, Payload, L = #link{rx_next_expected = E})
  when Seq =:= E ->
    L2 = bump_pending_ack(byte_size(Payload), Seq,
                          L#link{rx_next_expected = E + 1}),
    {deliver, Payload, L2};
apply_data(Seq, _Payload, L = #link{rx_next_expected = E}) when Seq < E ->
    {duplicate, L};
apply_data(Seq, _Payload, L = #link{rx_next_expected = E}) ->
    {protocol_error, {seq_skip, expected, E, got, Seq}, L}.

%% @doc Apply a peer FIN frame. Same in-order rules as DATA. On
%% accept, marks the RX side as FIN'd and forces an immediate ACK.
-spec apply_fin(non_neg_integer(), link_state()) ->
    {fin, link_state()}
  | {duplicate, link_state()}
  | {protocol_error, term(), link_state()}.
apply_fin(Seq, L = #link{rx_next_expected = E}) when Seq =:= E ->
    L2 = L#link{rx_next_expected = E + 1, rx_seen_fin = true,
                rx_pending_ack_bytes = ?MODULE:tx_unacked_bytes(L) + 1,
                rx_pending_ack_seq = Seq},
    %% bump_pending_ack would queue, but FIN is force-ack. Set
    %% pending_ack_seq directly so take_pending_ack/1 returns it.
    {fin, L2#link{rx_pending_ack_bytes = 16#FFFFFFFF}};
apply_fin(Seq, L = #link{rx_next_expected = E}) when Seq < E ->
    {duplicate, L};
apply_fin(Seq, L = #link{rx_next_expected = E}) ->
    {protocol_error, {seq_skip, expected, E, got, Seq}, L}.

%% @doc Apply a peer ACK frame. Drops every TX-unacked frame with
%% `Seq <= CumulativeSeq' and adjusts the byte counter so backpressure
%% releases.
-spec apply_ack(non_neg_integer(), link_state()) -> link_state().
apply_ack(CumulativeSeq, L = #link{tx_unacked = Q,
                                   tx_unacked_bytes = Bytes}) ->
    {Dropped, Q2, BytesAfter} = drop_until(CumulativeSeq, Q, Bytes, 0),
    _ = Dropped,
    L#link{tx_unacked = Q2, tx_unacked_bytes = BytesAfter}.

drop_until(CumulativeSeq, Q, BytesIn, Dropped) ->
    case queue:peek(Q) of
        {value, {Seq, _Sz, _Frame}} when Seq > CumulativeSeq ->
            {Dropped, Q, BytesIn};
        {value, {_Seq, Sz, _Frame}} ->
            Q2 = queue:drop(Q),
            drop_until(CumulativeSeq, Q2, BytesIn - Sz, Dropped + 1);
        empty ->
            {Dropped, Q, BytesIn}
    end.

%%====================================================================
%% Migration
%%====================================================================

%% @doc Build a `FRAME_RESUME' carrying our current `rx_next_expected'
%% and the supplied `Path' (empty for the destination -> initiator
%% reply leg). Used after the underlying stream has been re-opened on
%% a fresh path.
-spec build_resume([node()], link_state()) -> {binary(), link_state()}.
build_resume(Path, L = #link{circuit_id = Id, rx_next_expected = Rx}) ->
    Frame = mycelium_circuit_proto:encode_resume(Id, Rx, Path),
    {Frame, L}.

%% @doc Apply a peer RESUME (its `RxNextExpectedSeq'). Returns the
%% list of frames we should re-transmit (those still in tx_unacked
%% with `Seq >= PeerRxNext'), preserving original frame types (DATA
%% or FIN).
-spec apply_peer_resume(non_neg_integer(), [node()], link_state()) ->
    {ok, ReplayFrames :: [iodata()], link_state()}
  | {protocol_error, term(), link_state()}.
apply_peer_resume(PeerRxNext, _Path,
                  L = #link{tx_next_seq = TxNext}) when PeerRxNext > TxNext ->
    {protocol_error, {peer_rx_ahead, PeerRxNext, TxNext}, L};
apply_peer_resume(PeerRxNext, _Path,
                  L = #link{tx_unacked = Q, tx_unacked_bytes = Bytes}) ->
    %% Drop frames the peer says it has already received.
    {Q2, BytesAfter} = drop_strictly_below(PeerRxNext, Q, Bytes),
    %% Replay what's left in original frame-type order.
    Replay = [Frame || {_Seq, _Sz, Frame} <- queue:to_list(Q2)],
    {ok, Replay, L#link{tx_unacked = Q2, tx_unacked_bytes = BytesAfter}}.

drop_strictly_below(PeerRxNext, Q, Bytes) ->
    case queue:peek(Q) of
        {value, {Seq, _Sz, _Frame}} when Seq >= PeerRxNext ->
            {Q, Bytes};
        {value, {_Seq, Sz, _Frame}} ->
            drop_strictly_below(PeerRxNext, queue:drop(Q), Bytes - Sz);
        empty ->
            {Q, Bytes}
    end.

-spec pending_resume_replay(non_neg_integer(), link_state()) ->
    {[iodata()], link_state()}.
pending_resume_replay(PeerRxNext, L) ->
    case apply_peer_resume(PeerRxNext, [], L) of
        {ok, Replay, L2} -> {Replay, L2};
        {protocol_error, _, L2} -> {[], L2}
    end.

%%====================================================================
%% ACK pacing
%%====================================================================

%% Returns true iff we have buffered enough bytes to merit an ACK.
-spec pending_ack(link_state()) -> boolean().
pending_ack(#link{rx_pending_ack_seq = none}) -> false;
pending_ack(#link{rx_pending_ack_bytes = B,
                  ack_byte_threshold = T}) when B >= T -> true;
pending_ack(_) -> false.

%% @doc If an ACK is owed, return its frame and reset the pacing
%% counters. Otherwise return `none'.
-spec take_pending_ack(link_state()) ->
    {ok, AckFrame :: binary(), link_state()} | none.
take_pending_ack(#link{rx_pending_ack_seq = none}) ->
    none;
take_pending_ack(L = #link{rx_pending_ack_seq = Seq}) ->
    Frame = mycelium_circuit_proto:encode_ack(Seq),
    {ok, Frame, L#link{rx_pending_ack_seq = none, rx_pending_ack_bytes = 0}}.

%%====================================================================
%% Internal
%%====================================================================

%% Bump the pending-ack accumulator after delivering one in-order
%% frame. Seq is the just-delivered frame's seq; we record it as the
%% target cumulative ACK once we decide to flush.
bump_pending_ack(PayloadBytes, Seq,
                 L = #link{rx_pending_ack_bytes = B}) ->
    L#link{rx_pending_ack_bytes = B + PayloadBytes,
           rx_pending_ack_seq = Seq}.
