%%% -*- erlang -*-
%%%
%%% Mycelium Distribution Auth Stream
%%%
%%% Runs the Ed25519 challenge-response identity protocol over a pair
%%% of unidirectional QUIC streams, before the Erlang dist handshake.
%%% Each side opens its own unidirectional stream and writes its half
%%% of the protocol on it; reads are done from the peer's stream.
%%%
%%% Uni stream IDs (2,6,10,... client-init; 3,7,11,... server-init) do
%%% not collide with the bidi stream numbering the controller uses for
%%% the dist control stream (bidi 0, hardcoded server-side).
%%%
%%% Wire format on each stream: each protocol message from
%%% `mycelium_dist_protocol' is preceded by a 2-byte big-endian length
%%% prefix.
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
-spec authenticate_outgoing(Conn :: pid(), PeerNode :: node()) -> result().
authenticate_outgoing(Conn, PeerNode) ->
    case auth_enabled() of
        false ->
            ok;
        true ->
            run_outgoing(Conn, PeerNode)
    end.

%% @doc Run the auth protocol as the connection responder.
-spec authenticate_incoming(Conn :: pid(), Timeout :: timeout()) ->
    {ok, node() | undefined} | {error, term()}.
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
    case quic:open_unidirectional_stream(Conn) of
        {ok, MyStream} ->
            try
                do_outgoing(Conn, MyStream, PeerNode, Timeout)
            after
                catch quic:send_data(Conn, MyStream, <<>>, true)
            end;
        {error, Reason} ->
            {error, {open_auth_stream_failed, Reason}}
    end.

do_outgoing(Conn, MyStream, PeerNode, Timeout) ->
    case mycelium_dist_auth:get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            Hello = mycelium_dist_protocol:encode_hello(MyNode, MyPubKey),
            case stream_send(Conn, MyStream, Hello) of
                ok ->
                    case wait_for_peer_stream(Conn, Timeout) of
                        {ok, PeerStream, Buffer} ->
                            client_recv_hello(
                                Conn, MyStream, PeerStream, Buffer,
                                PeerNode, Timeout
                            );
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, {send_hello_failed, Reason}}
            end;
        Error ->
            Error
    end.

client_recv_hello(Conn, MyStream, PeerStream, Buffer, PeerNode, Timeout) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, HelloBin, Rest} ->
            case mycelium_dist_protocol:decode(HelloBin) of
                {hello, ClaimedNode, PeerPubKey} when ClaimedNode =:= PeerNode ->
                    client_send_challenge(
                        Conn, MyStream, PeerStream, Rest,
                        PeerNode, PeerPubKey, Timeout
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

client_send_challenge(Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout) ->
    {MyNonce, MyTs} = mycelium_dist_auth:create_challenge(),
    Msg = mycelium_dist_protocol:encode_challenge(MyNonce, MyTs),
    case stream_send(Conn, MyStream, Msg) of
        ok ->
            client_recv_challenge(
                Conn, MyStream, PeerStream, Buffer,
                PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
            );
        {error, Reason} ->
            {error, {send_challenge_failed, Reason}}
    end.

client_recv_challenge(
    Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, Bin, Rest} ->
            case mycelium_dist_protocol:decode(Bin) of
                {challenge, PeerNonce, PeerTs} ->
                    client_send_response(
                        Conn, MyStream, PeerStream, Rest,
                        PeerNode, PeerPubKey,
                        MyNonce, MyTs, PeerNonce, PeerTs, Timeout
                    );
                {fail, Reason} ->
                    {error, {auth_rejected, Reason}};
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_challenge_failed, Reason}}
    end.

client_send_response(
    Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey,
    MyNonce, MyTs, PeerNonce, PeerTs, Timeout
) ->
    case sign_for_peer(PeerNonce, PeerTs, PeerPubKey) of
        {ok, MySig} ->
            Resp = mycelium_dist_protocol:encode_response(MySig),
            case stream_send(Conn, MyStream, Resp) of
                ok ->
                    client_recv_response(
                        Conn, PeerStream, Buffer,
                        PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
                    );
                {error, Reason} ->
                    {error, {send_response_failed, Reason}}
            end;
        Error ->
            Error
    end.

client_recv_response(Conn, PeerStream, Buffer, PeerNode, PeerPubKey, MyNonce, MyTs, Timeout) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, Bin, Rest} ->
            case mycelium_dist_protocol:decode(Bin) of
                {response, PeerSig} ->
                    case
                        mycelium_dist_auth:verify_response(
                            PeerSig, PeerPubKey, {MyNonce, MyTs}
                        )
                    of
                        true ->
                            client_recv_ok(
                                Conn, PeerStream, Rest,
                                PeerNode, PeerPubKey, Timeout
                            );
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

client_recv_ok(Conn, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, Bin, _Rest} ->
            case mycelium_dist_protocol:decode(Bin) of
                ok ->
                    record_peer(PeerNode, PeerPubKey);
                {fail, Reason} ->
                    {error, {auth_rejected, Reason}};
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_ok_failed, Reason}}
    end.

%%====================================================================
%% Incoming (server) side
%%====================================================================

run_incoming(Conn, Timeout) ->
    case wait_for_peer_stream(Conn, Timeout) of
        {ok, PeerStream, Buffer} ->
            do_incoming(Conn, PeerStream, Buffer, Timeout);
        {error, Reason} ->
            {error, Reason}
    end.

do_incoming(Conn, PeerStream, Buffer, Timeout) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, HelloBin, Rest} ->
            case mycelium_dist_protocol:decode(HelloBin) of
                {hello, PeerNode, PeerPubKey} ->
                    server_after_hello(
                        Conn, PeerStream, Rest, PeerNode, PeerPubKey, Timeout
                    );
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_hello_failed, Reason}}
    end.

server_after_hello(Conn, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout) ->
    case mycelium_dist_keys:is_trusted(PeerNode, PeerPubKey) of
        true ->
            server_open_my_stream(
                Conn, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout
            );
        false ->
            case trust_mode() of
                tofu ->
                    server_open_my_stream(
                        Conn, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout
                    );
                strict ->
                    send_fail_via_uni(Conn, <<"untrusted_key">>),
                    {error, untrusted_key}
            end
    end.

server_open_my_stream(Conn, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout) ->
    case quic:open_unidirectional_stream(Conn) of
        {ok, MyStream} ->
            try
                server_send_hello(
                    Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout
                )
            after
                catch quic:send_data(Conn, MyStream, <<>>, true)
            end;
        {error, Reason} ->
            {error, {open_auth_stream_failed, Reason}}
    end.

server_send_hello(Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout) ->
    case mycelium_dist_auth:get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            Hello = mycelium_dist_protocol:encode_hello(MyNode, MyPubKey),
            case stream_send(Conn, MyStream, Hello) of
                ok ->
                    server_send_challenge(
                        Conn, MyStream, PeerStream, Buffer,
                        PeerNode, PeerPubKey, Timeout
                    );
                {error, Reason} ->
                    {error, {send_hello_failed, Reason}}
            end;
        Error ->
            Error
    end.

server_send_challenge(Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey, Timeout) ->
    {MyNonce, MyTs} = mycelium_dist_auth:create_challenge(),
    Msg = mycelium_dist_protocol:encode_challenge(MyNonce, MyTs),
    case stream_send(Conn, MyStream, Msg) of
        ok ->
            server_recv_challenge(
                Conn, MyStream, PeerStream, Buffer,
                PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
            );
        {error, Reason} ->
            {error, {send_challenge_failed, Reason}}
    end.

server_recv_challenge(
    Conn, MyStream, PeerStream, Buffer,
    PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, Bin, Rest} ->
            case mycelium_dist_protocol:decode(Bin) of
                {challenge, PeerNonce, PeerTs} ->
                    server_send_response(
                        Conn, MyStream, PeerStream, Rest,
                        PeerNode, PeerPubKey,
                        MyNonce, MyTs, PeerNonce, PeerTs, Timeout
                    );
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_challenge_failed, Reason}}
    end.

server_send_response(
    Conn, MyStream, PeerStream, Buffer, PeerNode, PeerPubKey,
    MyNonce, MyTs, PeerNonce, PeerTs, Timeout
) ->
    case sign_for_peer(PeerNonce, PeerTs, PeerPubKey) of
        {ok, MySig} ->
            Resp = mycelium_dist_protocol:encode_response(MySig),
            case stream_send(Conn, MyStream, Resp) of
                ok ->
                    server_recv_response(
                        Conn, MyStream, PeerStream, Buffer,
                        PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
                    );
                {error, Reason} ->
                    {error, {send_response_failed, Reason}}
            end;
        Error ->
            Error
    end.

server_recv_response(
    Conn, MyStream, PeerStream, Buffer,
    PeerNode, PeerPubKey, MyNonce, MyTs, Timeout
) ->
    case decode_with_buffer(Conn, PeerStream, Buffer, Timeout) of
        {ok, Bin, _Rest} ->
            case mycelium_dist_protocol:decode(Bin) of
                {response, PeerSig} ->
                    case
                        mycelium_dist_auth:verify_response(
                            PeerSig, PeerPubKey, {MyNonce, MyTs}
                        )
                    of
                        true ->
                            server_send_ok(Conn, MyStream, PeerNode, PeerPubKey);
                        false ->
                            send_fail(Conn, MyStream, <<"signature_invalid">>),
                            {error, signature_verification_failed}
                    end;
                Other ->
                    {error, {unexpected_message, Other}}
            end;
        {error, Reason} ->
            {error, {recv_response_failed, Reason}}
    end.

server_send_ok(Conn, MyStream, PeerNode, PeerPubKey) ->
    case stream_send(Conn, MyStream, mycelium_dist_protocol:encode_ok()) of
        ok ->
            ok = record_peer(PeerNode, PeerPubKey),
            {ok, PeerNode};
        {error, Reason} ->
            {error, {send_ok_failed, Reason}}
    end.

%%====================================================================
%% Stream IO with length framing
%%====================================================================

stream_send(Conn, StreamId, Msg) ->
    Len = byte_size(Msg),
    Framed = <<Len:(?LEN_SIZE * 8)/big, Msg/binary>>,
    quic:send_data(Conn, StreamId, Framed, false).

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

%% Wait for the peer's stream to be opened, returning its id and the
%% first chunk of data. Accept both `stream_opened' notifications and
%% direct `stream_data' arrivals.
wait_for_peer_stream(Conn, Timeout) ->
    receive
        {quic, Conn, {stream_opened, StreamId}} ->
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

%%====================================================================
%% Helpers
%%====================================================================

sign_for_peer(Nonce, Timestamp, _PeerPubKey) ->
    %% Sign <Nonce | Timestamp | OwnPubKey>. The peer verifies via
    %% mycelium_dist_auth:verify_response/3 which rebuilds the message
    %% as <Nonce | Timestamp | ResponderPubKey> (== our pubkey from the
    %% peer's perspective). Including the responder's own pubkey gives
    %% channel binding to the responder's identity; including the peer's
    %% pubkey instead leaves the verifier unable to reproduce the
    %% message.
    case mycelium_dist_auth:get_private_key() of
        {ok, PrivKey} ->
            case mycelium_dist_auth:get_public_key() of
                {ok, MyPubKey} ->
                    Message =
                        <<Nonce/binary, Timestamp:64/big, MyPubKey/binary>>,
                    Sig = crypto:sign(eddsa, none, Message, [PrivKey, ed25519]),
                    {ok, Sig};
                Error -> Error
            end;
        Error ->
            Error
    end.

send_fail(Conn, StreamId, Reason) ->
    Msg = mycelium_dist_protocol:encode_fail(Reason),
    _ = stream_send(Conn, StreamId, Msg),
    ok.

%% Open a fresh uni stream just to deliver a FAIL message (used when we
%% reject before opening the normal server-side auth stream).
send_fail_via_uni(Conn, Reason) ->
    case quic:open_unidirectional_stream(Conn) of
        {ok, S} ->
            send_fail(Conn, S, Reason),
            catch quic:send_data(Conn, S, <<>>, true),
            ok;
        _ ->
            ok
    end.

record_peer(PeerNode, PeerPubKey) ->
    case trust_mode() of
        strict ->
            ok;
        tofu ->
            _ = mycelium_dist_keys:store_key_if_new(PeerNode, PeerPubKey),
            ok
    end.

auth_enabled() ->
    %% Default false: auth is opt-in. Production sys.config sets true
    %% explicitly. Defaulting to true would crash any node that uses
    %% -proto_dist mycelium without first loading the mycelium app, since
    %% get_public_key/0 reads keys from disk that only get_provisioned
    %% when the supervision tree starts mycelium_dist_keys.
    application:get_env(mycelium, auth_enabled, false).

trust_mode() ->
    application:get_env(mycelium, auth_trust_mode, tofu).

handshake_timeout() ->
    application:get_env(mycelium, auth_handshake_timeout, 10000).
