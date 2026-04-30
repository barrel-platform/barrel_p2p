%%% -*- erlang -*-
%%%
%%% Mycelium Distribution Auth Stream
%%%
%%% Runs the Ed25519 challenge-response identity protocol over a
%%% dedicated QUIC stream, before the Erlang dist handshake. The
%%% stream is opened by the connection initiator on a fresh QUIC
%%% connection and accepted by the responder. On success the stream
%%% closes (FIN both ways) and `mycelium_dist' proceeds to start the
%%% controller and run `dist_util'. On failure the caller is expected
%%% to drop the QUIC connection.
%%%
%%% Wire format on the stream: each protocol message from
%%% `mycelium_dist_protocol' is preceded by a 2-byte big-endian
%%% length prefix. This matches the framing the upstream dist
%%% handshake uses pre-`dist_util' on the control stream.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mycelium_dist_auth_stream).

-export([
    authenticate_outgoing/2,
    authenticate_incoming/2
]).

-include("mycelium_dist.hrl").

-define(LEN_SIZE, ?MYCELIUM_DIST_HS_LEN_SIZE).

-type result() :: ok | {error, term()}.

%%====================================================================
%% Public API
%%====================================================================

%% @doc Run the auth protocol as the connection initiator.
%% Opens a fresh bidirectional QUIC stream on `Conn', exchanges the
%% Ed25519 challenge-response and returns when the peer's identity has
%% been verified (and recorded in TOFU mode).
-spec authenticate_outgoing(Conn :: pid(), PeerNode :: node()) -> result().
authenticate_outgoing(Conn, PeerNode) ->
    case auth_enabled() of
        false ->
            ok;
        true ->
            run_outgoing(Conn, PeerNode)
    end.

%% @doc Run the auth protocol as the connection responder.
%% Waits for the initiator to open the auth stream on `Conn', drives
%% the protocol and returns the peer node name on success.
-spec authenticate_incoming(Conn :: pid(), Timeout :: timeout()) ->
    {ok, node()} | {error, term()}.
authenticate_incoming(Conn, Timeout) ->
    case auth_enabled() of
        false ->
            {ok, undefined};
        true ->
            run_incoming(Conn, Timeout)
    end.

%%====================================================================
%% Outgoing (client) side
%%====================================================================

run_outgoing(Conn, PeerNode) ->
    Timeout = handshake_timeout(),
    case quic:open_stream(Conn) of
        {ok, StreamId} ->
            try
                do_outgoing(Conn, StreamId, PeerNode, Timeout)
            after
                catch quic:send_data(Conn, StreamId, <<>>, true)
            end;
        {error, Reason} ->
            {error, {open_auth_stream_failed, Reason}}
    end.

do_outgoing(Conn, StreamId, PeerNode, Timeout) ->
    case mycelium_dist_auth:get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            HelloMsg = mycelium_dist_protocol:encode_hello(MyNode, MyPubKey),
            case stream_send(Conn, StreamId, HelloMsg) of
                ok ->
                    recv_peer_hello(Conn, StreamId, PeerNode, MyPubKey, Timeout);
                {error, Reason} ->
                    {error, {send_hello_failed, Reason}}
            end;
        Error ->
            Error
    end.

recv_peer_hello(Conn, StreamId, PeerNode, MyPubKey, Timeout) ->
    case stream_recv(Conn, StreamId, Timeout) of
        {ok, Data} ->
            case mycelium_dist_protocol:decode(Data) of
                {hello, ClaimedNode, PeerPubKey} when ClaimedNode =:= PeerNode ->
                    outgoing_send_challenge(
                        Conn, StreamId, PeerNode, MyPubKey, PeerPubKey, Timeout
                    );
                {hello, Other, _} ->
                    {error, {node_mismatch, {expected, PeerNode}, {got, Other}}};
                {fail, Reason} ->
                    {error, {auth_rejected, Reason}};
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_hello_failed, Reason}}
    end.

outgoing_send_challenge(Conn, StreamId, PeerNode, MyPubKey, PeerPubKey, Timeout) ->
    {MyNonce, MyTimestamp} = mycelium_dist_auth:create_challenge(),
    Msg = mycelium_dist_protocol:encode_challenge(MyNonce, MyTimestamp),
    case stream_send(Conn, StreamId, Msg) of
        ok ->
            outgoing_recv_challenge(
                Conn,
                StreamId,
                PeerNode,
                MyPubKey,
                PeerPubKey,
                MyNonce,
                MyTimestamp,
                Timeout
            );
        {error, Reason} ->
            {error, {send_challenge_failed, Reason}}
    end.

outgoing_recv_challenge(
    Conn, StreamId, PeerNode, MyPubKey, PeerPubKey, MyNonce, MyTimestamp, Timeout
) ->
    case stream_recv(Conn, StreamId, Timeout) of
        {ok, Data} ->
            case mycelium_dist_protocol:decode(Data) of
                {challenge, PeerNonce, PeerTimestamp} ->
                    outgoing_send_response(
                        Conn,
                        StreamId,
                        PeerNode,
                        MyPubKey,
                        PeerPubKey,
                        MyNonce,
                        MyTimestamp,
                        PeerNonce,
                        PeerTimestamp,
                        Timeout
                    );
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_challenge_failed, Reason}}
    end.

outgoing_send_response(
    Conn,
    StreamId,
    PeerNode,
    _MyPubKey,
    PeerPubKey,
    MyNonce,
    MyTimestamp,
    PeerNonce,
    PeerTimestamp,
    Timeout
) ->
    case sign_for_peer(PeerNonce, PeerTimestamp, PeerPubKey) of
        {ok, MySig} ->
            case stream_send(Conn, StreamId, mycelium_dist_protocol:encode_response(MySig)) of
                ok ->
                    outgoing_recv_response(
                        Conn,
                        StreamId,
                        PeerNode,
                        PeerPubKey,
                        MyNonce,
                        MyTimestamp,
                        Timeout
                    );
                {error, Reason} ->
                    {error, {send_response_failed, Reason}}
            end;
        Error ->
            Error
    end.

outgoing_recv_response(Conn, StreamId, PeerNode, PeerPubKey, MyNonce, MyTimestamp, Timeout) ->
    case stream_recv(Conn, StreamId, Timeout) of
        {ok, Data} ->
            case mycelium_dist_protocol:decode(Data) of
                {response, PeerSig} ->
                    case
                        mycelium_dist_auth:verify_response(
                            PeerSig, PeerPubKey, {MyNonce, MyTimestamp}
                        )
                    of
                        true ->
                            outgoing_finalize(Conn, StreamId, PeerNode, PeerPubKey, Timeout);
                        false ->
                            {error, signature_verification_failed}
                    end;
                {fail, Reason} ->
                    {error, {auth_rejected, Reason}};
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_response_failed, Reason}}
    end.

outgoing_finalize(Conn, StreamId, PeerNode, PeerPubKey, Timeout) ->
    case stream_recv(Conn, StreamId, Timeout) of
        {ok, Data} ->
            case mycelium_dist_protocol:decode(Data) of
                ok ->
                    record_peer(PeerNode, PeerPubKey);
                {fail, Reason} ->
                    {error, {auth_rejected, Reason}};
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_final_failed, Reason}}
    end.

%%====================================================================
%% Incoming (server) side
%%====================================================================

run_incoming(Conn, Timeout) ->
    case wait_for_auth_stream(Conn, Timeout) of
        {ok, StreamId, FirstChunk} ->
            try
                do_incoming(Conn, StreamId, FirstChunk, Timeout)
            after
                catch quic:send_data(Conn, StreamId, <<>>, true)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Wait for the initiator's first stream and its first data frame. We
%% accept both `new_stream' notifications and a `stream_data' arriving
%% directly (some QUIC stacks elide the explicit new_stream event for
%% client-initiated bidi streams).
wait_for_auth_stream(Conn, Timeout) ->
    receive
        {quic, Conn, {new_stream, StreamId}} ->
            recv_first_chunk(Conn, StreamId, Timeout);
        {quic, Conn, {stream_data, StreamId, Data, _Fin}} ->
            {ok, StreamId, Data};
        {quic, Conn, {closed, Reason}} ->
            {error, {connection_closed, Reason}};
        {quic, Conn, {transport_error, Code, Reason}} ->
            {error, {transport_error, Code, Reason}}
    after Timeout ->
        {error, auth_stream_timeout}
    end.

recv_first_chunk(Conn, StreamId, Timeout) ->
    receive
        {quic, Conn, {stream_data, StreamId, Data, _Fin}} ->
            {ok, StreamId, Data};
        {quic, Conn, {stream_reset, StreamId, Code}} ->
            {error, {stream_reset, Code}};
        {quic, Conn, {closed, Reason}} ->
            {error, {connection_closed, Reason}}
    after Timeout ->
        {error, auth_stream_timeout}
    end.

do_incoming(Conn, StreamId, FirstChunk, Timeout) ->
    case mycelium_dist_auth:get_public_key() of
        {ok, MyPubKey} ->
            case decode_with_buffer(Conn, StreamId, FirstChunk, Timeout) of
                {ok, HelloBin, Rest} ->
                    case mycelium_dist_protocol:decode(HelloBin) of
                        {hello, PeerNode, PeerPubKey} ->
                            incoming_after_hello(
                                Conn, StreamId, MyPubKey, PeerNode, PeerPubKey, Rest, Timeout
                            );
                        Other ->
                            send_fail(Conn, StreamId, <<"bad_hello">>),
                            {error, {unexpected_message, Other}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        Error ->
            Error
    end.

incoming_after_hello(Conn, StreamId, MyPubKey, PeerNode, PeerPubKey, Buffer, Timeout) ->
    case mycelium_dist_keys:is_trusted(PeerNode, PeerPubKey) of
        true ->
            incoming_send_hello(
                Conn, StreamId, MyPubKey, PeerNode, PeerPubKey, Buffer, Timeout
            );
        false ->
            case trust_mode() of
                tofu ->
                    incoming_send_hello(
                        Conn, StreamId, MyPubKey, PeerNode, PeerPubKey, Buffer, Timeout
                    );
                strict ->
                    send_fail(Conn, StreamId, <<"untrusted_key">>),
                    {error, untrusted_key}
            end
    end.

incoming_send_hello(Conn, StreamId, MyPubKey, PeerNode, PeerPubKey, Buffer, Timeout) ->
    MyNode = node(),
    Msg = mycelium_dist_protocol:encode_hello(MyNode, MyPubKey),
    case stream_send(Conn, StreamId, Msg) of
        ok ->
            incoming_recv_challenge(
                Conn, StreamId, PeerNode, PeerPubKey, Buffer, Timeout
            );
        {error, Reason} ->
            {error, {send_hello_failed, Reason}}
    end.

incoming_recv_challenge(Conn, StreamId, PeerNode, PeerPubKey, Buffer, Timeout) ->
    case decode_with_buffer(Conn, StreamId, Buffer, Timeout) of
        {ok, ChallengeBin, Rest} ->
            case mycelium_dist_protocol:decode(ChallengeBin) of
                {challenge, PeerNonce, PeerTimestamp} ->
                    incoming_send_challenge(
                        Conn,
                        StreamId,
                        PeerNode,
                        PeerPubKey,
                        PeerNonce,
                        PeerTimestamp,
                        Rest,
                        Timeout
                    );
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

incoming_send_challenge(
    Conn, StreamId, PeerNode, PeerPubKey, PeerNonce, PeerTimestamp, Buffer, Timeout
) ->
    {MyNonce, MyTimestamp} = mycelium_dist_auth:create_challenge(),
    Msg = mycelium_dist_protocol:encode_challenge(MyNonce, MyTimestamp),
    case stream_send(Conn, StreamId, Msg) of
        ok ->
            incoming_recv_response(
                Conn,
                StreamId,
                PeerNode,
                PeerPubKey,
                MyNonce,
                MyTimestamp,
                PeerNonce,
                PeerTimestamp,
                Buffer,
                Timeout
            );
        {error, Reason} ->
            {error, {send_challenge_failed, Reason}}
    end.

incoming_recv_response(
    Conn,
    StreamId,
    PeerNode,
    PeerPubKey,
    MyNonce,
    MyTimestamp,
    PeerNonce,
    PeerTimestamp,
    Buffer,
    Timeout
) ->
    case decode_with_buffer(Conn, StreamId, Buffer, Timeout) of
        {ok, Bin, Rest} ->
            case mycelium_dist_protocol:decode(Bin) of
                {response, PeerSig} ->
                    case
                        mycelium_dist_auth:verify_response(
                            PeerSig, PeerPubKey, {MyNonce, MyTimestamp}
                        )
                    of
                        true ->
                            incoming_send_response_and_ok(
                                Conn,
                                StreamId,
                                PeerNode,
                                PeerPubKey,
                                PeerNonce,
                                PeerTimestamp,
                                Rest
                            );
                        false ->
                            send_fail(Conn, StreamId, <<"signature_invalid">>),
                            {error, signature_verification_failed}
                    end;
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

incoming_send_response_and_ok(
    Conn, StreamId, PeerNode, PeerPubKey, PeerNonce, PeerTimestamp, _Buffer
) ->
    case sign_for_peer(PeerNonce, PeerTimestamp, PeerPubKey) of
        {ok, MySig} ->
            case stream_send(Conn, StreamId, mycelium_dist_protocol:encode_response(MySig)) of
                ok ->
                    case stream_send(Conn, StreamId, mycelium_dist_protocol:encode_ok()) of
                        ok ->
                            case record_peer(PeerNode, PeerPubKey) of
                                ok -> {ok, PeerNode};
                                Err -> Err
                            end;
                        {error, Reason} ->
                            {error, {send_ok_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {send_response_failed, Reason}}
            end;
        Error ->
            Error
    end.

%%====================================================================
%% Stream IO with length framing
%%====================================================================

stream_send(Conn, StreamId, Msg) ->
    Len = byte_size(Msg),
    Framed = <<Len:(?LEN_SIZE * 8)/big, Msg/binary>>,
    quic:send_data(Conn, StreamId, Framed, false).

%% Read one length-prefixed message from the stream, draining as much
%% data as needed; returns any leftover bytes for the next call.
stream_recv(Conn, StreamId, Timeout) ->
    decode_with_buffer(Conn, StreamId, <<>>, Timeout).

decode_with_buffer(Conn, StreamId, Buffer, Timeout) ->
    case Buffer of
        <<Len:(?LEN_SIZE * 8)/big, Rest/binary>> when byte_size(Rest) >= Len ->
            <<Msg:Len/binary, Tail/binary>> = Rest,
            {ok, Msg, Tail};
        _ ->
            case recv_more(Conn, StreamId, Timeout) of
                {ok, More} ->
                    decode_with_buffer(
                        Conn, StreamId, <<Buffer/binary, More/binary>>, Timeout
                    );
                {error, Reason} ->
                    {error, Reason}
            end
    end.

recv_more(Conn, StreamId, Timeout) ->
    receive
        {quic, Conn, {stream_data, StreamId, Data, _Fin}} ->
            {ok, Data};
        {quic, Conn, {stream_reset, StreamId, Code}} ->
            {error, {stream_reset, Code}};
        {quic, Conn, {closed, Reason}} ->
            {error, {connection_closed, Reason}};
        {quic, Conn, {transport_error, Code, Reason}} ->
            {error, {transport_error, Code, Reason}}
    after Timeout ->
        {error, auth_stream_timeout}
    end.

%%====================================================================
%% Helpers
%%====================================================================

sign_for_peer(Nonce, Timestamp, PeerPubKey) ->
    case mycelium_dist_auth:get_private_key() of
        {ok, PrivKey} ->
            Message = <<Nonce/binary, Timestamp:64/big, PeerPubKey/binary>>,
            Sig = crypto:sign(eddsa, none, Message, [PrivKey, ed25519]),
            {ok, Sig};
        Error ->
            Error
    end.

send_fail(Conn, StreamId, Reason) ->
    Msg = mycelium_dist_protocol:encode_fail(Reason),
    _ = stream_send(Conn, StreamId, Msg),
    ok.

record_peer(PeerNode, PeerPubKey) ->
    case trust_mode() of
        strict ->
            ok;
        tofu ->
            _ = mycelium_dist_keys:store_key_if_new(PeerNode, PeerPubKey),
            ok
    end.

auth_enabled() ->
    application:get_env(mycelium, auth_enabled, true).

trust_mode() ->
    application:get_env(mycelium, auth_trust_mode, tofu).

handshake_timeout() ->
    application:get_env(mycelium, auth_handshake_timeout, 10000).
