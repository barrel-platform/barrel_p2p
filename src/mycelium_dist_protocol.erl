-module(mycelium_dist_protocol).

%% Wire protocol encoding for Ed25519 distribution authentication
%% Message format: <<Type:8, Length:16/big, Payload/binary>>

-export([
    encode_hello/2,
    encode_challenge/2,
    encode_response/1,
    encode_ok/0,
    encode_fail/1,
    encode_key_exchange/1,
    decode/1
]).

%% Protocol version
-define(PROTOCOL_VERSION, 1).

%% Message types
-define(AUTH_HELLO, 1).
-define(AUTH_CHALLENGE, 2).
-define(AUTH_RESPONSE, 3).
-define(AUTH_OK, 4).
-define(AUTH_FAIL, 5).
-define(AUTH_KEY_EXCHANGE, 6).

%% Key sizes
-define(PUBLIC_KEY_SIZE, 32).
-define(X25519_KEY_SIZE, 32).
-define(NONCE_SIZE, 32).
-define(SIGNATURE_SIZE, 64).

%%====================================================================
%% Encoding Functions
%%====================================================================

%% @doc Encode AUTH_HELLO message
%% Format: <<Type:8, Version:8, NodeNameLen:16/big, NodeName/binary, PubKey:32/binary>>
-spec encode_hello(node(), binary()) -> binary().
encode_hello(NodeName, PubKey) when byte_size(PubKey) =:= ?PUBLIC_KEY_SIZE ->
    NodeBin = atom_to_binary(NodeName, utf8),
    NodeLen = byte_size(NodeBin),
    Payload = <<?PROTOCOL_VERSION:8, NodeLen:16/big, NodeBin/binary, PubKey/binary>>,
    <<?AUTH_HELLO:8, Payload/binary>>.

%% @doc Encode AUTH_CHALLENGE message
%% Format: <<Type:8, Nonce:32/binary, Timestamp:64/big>>
-spec encode_challenge(binary(), integer()) -> binary().
encode_challenge(Nonce, Timestamp) when byte_size(Nonce) =:= ?NONCE_SIZE ->
    Payload = <<Nonce/binary, Timestamp:64/big>>,
    <<?AUTH_CHALLENGE:8, Payload/binary>>.

%% @doc Encode AUTH_RESPONSE message
%% Format: <<Type:8, Signature:64/binary>>
-spec encode_response(binary()) -> binary().
encode_response(Signature) when byte_size(Signature) =:= ?SIGNATURE_SIZE ->
    <<?AUTH_RESPONSE:8, Signature/binary>>.

%% @doc Encode AUTH_OK message
%% Format: <<Type:8>>
-spec encode_ok() -> binary().
encode_ok() ->
    <<?AUTH_OK:8>>.

%% @doc Encode AUTH_FAIL message
%% Format: <<Type:8, ReasonLen:16/big, Reason/binary>>
-spec encode_fail(binary()) -> binary().
encode_fail(Reason) when is_binary(Reason) ->
    ReasonLen = byte_size(Reason),
    <<?AUTH_FAIL:8, ReasonLen:16/big, Reason/binary>>.

%% @doc Encode AUTH_KEY_EXCHANGE message
%% Format: <<Type:8, EphemeralPubKey:32/binary>>
-spec encode_key_exchange(binary()) -> binary().
encode_key_exchange(EphemeralPubKey) when byte_size(EphemeralPubKey) =:= ?X25519_KEY_SIZE ->
    <<?AUTH_KEY_EXCHANGE:8, EphemeralPubKey/binary>>.

%%====================================================================
%% Decoding Functions
%%====================================================================

%% @doc Decode an authentication message
-spec decode(binary()) ->
    {hello, node(), binary()} |
    {challenge, binary(), integer()} |
    {response, binary()} |
    ok |
    {fail, binary()} |
    {error, term()}.
decode(<<?AUTH_HELLO:8, ?PROTOCOL_VERSION:8, NodeLen:16/big, Rest/binary>>) ->
    case Rest of
        <<NodeBin:NodeLen/binary, PubKey:?PUBLIC_KEY_SIZE/binary>> ->
            try
                NodeName = binary_to_atom(NodeBin, utf8),
                {hello, NodeName, PubKey}
            catch
                _:_ -> {error, invalid_node_name}
            end;
        _ ->
            {error, invalid_hello_payload}
    end;
decode(<<?AUTH_HELLO:8, Version:8, _/binary>>) ->
    {error, {unsupported_version, Version}};

decode(<<?AUTH_CHALLENGE:8, Nonce:?NONCE_SIZE/binary, Timestamp:64/big>>) ->
    {challenge, Nonce, Timestamp};
decode(<<?AUTH_CHALLENGE:8, _/binary>>) ->
    {error, invalid_challenge_payload};

decode(<<?AUTH_RESPONSE:8, Signature:?SIGNATURE_SIZE/binary>>) ->
    {response, Signature};
decode(<<?AUTH_RESPONSE:8, _/binary>>) ->
    {error, invalid_response_payload};

decode(<<?AUTH_OK:8>>) ->
    ok;

decode(<<?AUTH_FAIL:8, ReasonLen:16/big, Reason:ReasonLen/binary>>) ->
    {fail, Reason};
decode(<<?AUTH_FAIL:8, _/binary>>) ->
    {error, invalid_fail_payload};

decode(<<?AUTH_KEY_EXCHANGE:8, EphemeralPubKey:?X25519_KEY_SIZE/binary>>) ->
    {key_exchange, EphemeralPubKey};
decode(<<?AUTH_KEY_EXCHANGE:8, _/binary>>) ->
    {error, invalid_key_exchange_payload};

decode(<<Type:8, _/binary>>) ->
    {error, {unknown_message_type, Type}};

decode(_) ->
    {error, malformed_message}.
