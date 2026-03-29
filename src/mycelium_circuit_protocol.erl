-module(mycelium_circuit_protocol).

%% Circuit routing protocol encoding/decoding
%%
%% Message format:
%%   <<Type:8, CircuitIdLen:16, CircuitId/binary, Payload/binary>>
%%
%% Type values defined in mycelium.hrl:
%%   1 = CREATE   - Initiator -> first relay (includes ephemeral pubkey)
%%   2 = CREATED  - Response acknowledging circuit creation (includes pubkey)
%%   3 = EXTEND   - Request to extend circuit to next hop
%%   4 = EXTENDED - Response acknowledging extension
%%   5 = DATA     - Encrypted data payload
%%   6 = DESTROY  - Tear down circuit

-include("mycelium.hrl").

-export([
    %% Encoding
    encode_create/2,
    encode_created/2,
    encode_extend/3,
    encode_extended/2,
    encode_data/2,
    encode_destroy/2,

    %% Decoding
    decode/1,

    %% Message handling
    handle_message/3
]).

-define(CIRCUIT_ID_SIZE, 16).
-define(PUBKEY_SIZE, 32).

%%====================================================================
%% Encoding Functions
%%====================================================================

%% @doc Encode CREATE message - start a new circuit
%% Includes the initiator's ephemeral public key for key exchange
-spec encode_create(#circuit_id{}, EphemeralPubKey :: binary()) -> binary().
encode_create(CircuitId, EphemeralPubKey) when byte_size(EphemeralPubKey) =:= ?PUBKEY_SIZE ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<?CIRCUIT_CREATE:8, IdLen:16, IdBin/binary, EphemeralPubKey/binary>>.

%% @doc Encode CREATED response - circuit creation acknowledged
%% Includes the responder's ephemeral public key for key exchange
-spec encode_created(#circuit_id{}, EphemeralPubKey :: binary()) -> binary().
encode_created(CircuitId, EphemeralPubKey) when byte_size(EphemeralPubKey) =:= ?PUBKEY_SIZE ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<?CIRCUIT_CREATED:8, IdLen:16, IdBin/binary, EphemeralPubKey/binary>>.

%% @doc Encode EXTEND message - request to extend circuit to next hop
%% Includes target node and initiator's ephemeral public key for E2E encryption
-spec encode_extend(#circuit_id{}, TargetNode :: node(), EphemeralPubKey :: binary()) -> binary().
encode_extend(CircuitId, TargetNode, EphemeralPubKey) when byte_size(EphemeralPubKey) =:= ?PUBKEY_SIZE ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    TargetBin = atom_to_binary(TargetNode, utf8),
    TargetLen = byte_size(TargetBin),
    <<?CIRCUIT_EXTEND:8, IdLen:16, IdBin/binary,
      TargetLen:16, TargetBin/binary, EphemeralPubKey/binary>>.

%% @doc Encode EXTENDED response - circuit extension acknowledged
%% Includes the destination's ephemeral public key for E2E encryption
-spec encode_extended(#circuit_id{}, EphemeralPubKey :: binary()) -> binary().
encode_extended(CircuitId, EphemeralPubKey) when byte_size(EphemeralPubKey) =:= ?PUBKEY_SIZE ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<?CIRCUIT_EXTENDED:8, IdLen:16, IdBin/binary, EphemeralPubKey/binary>>.

%% @doc Encode DATA message - encrypted payload
-spec encode_data(#circuit_id{}, EncryptedPayload :: binary()) -> binary().
encode_data(CircuitId, EncryptedPayload) ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<?CIRCUIT_DATA:8, IdLen:16, IdBin/binary, EncryptedPayload/binary>>.

%% @doc Encode DESTROY message - tear down circuit
%% Reason: 0=normal, 1=timeout, 2=error
-spec encode_destroy(#circuit_id{}, Reason :: non_neg_integer()) -> binary().
encode_destroy(CircuitId, Reason) ->
    IdBin = encode_circuit_id(CircuitId),
    IdLen = byte_size(IdBin),
    <<?CIRCUIT_DESTROY:8, IdLen:16, IdBin/binary, Reason:8>>.

%%====================================================================
%% Decoding Functions
%%====================================================================

%% @doc Decode a circuit protocol message
-spec decode(binary()) -> {ok, {Type :: atom(), #circuit_id{}, Payload :: term()}} | {error, term()}.
decode(<<Type:8, IdLen:16, IdBin:IdLen/binary, Rest/binary>>) ->
    case decode_circuit_id(IdBin) of
        {ok, CircuitId} ->
            decode_payload(Type, CircuitId, Rest);
        {error, _} = Error ->
            Error
    end;
decode(_) ->
    {error, invalid_message}.

decode_payload(?CIRCUIT_CREATE, CircuitId, <<EphPubKey:?PUBKEY_SIZE/binary>>) ->
    {ok, {create, CircuitId, EphPubKey}};
decode_payload(?CIRCUIT_CREATED, CircuitId, <<EphPubKey:?PUBKEY_SIZE/binary>>) ->
    {ok, {created, CircuitId, EphPubKey}};
decode_payload(?CIRCUIT_EXTEND, CircuitId, <<TargetLen:16, TargetBin:TargetLen/binary, EphPubKey:?PUBKEY_SIZE/binary>>) ->
    TargetNode = binary_to_atom(TargetBin, utf8),
    {ok, {extend, CircuitId, {TargetNode, EphPubKey}}};
decode_payload(?CIRCUIT_EXTENDED, CircuitId, <<EphPubKey:?PUBKEY_SIZE/binary>>) ->
    {ok, {extended, CircuitId, EphPubKey}};
decode_payload(?CIRCUIT_DATA, CircuitId, EncryptedPayload) ->
    {ok, {data, CircuitId, EncryptedPayload}};
decode_payload(?CIRCUIT_DESTROY, CircuitId, <<Reason:8>>) ->
    {ok, {destroy, CircuitId, Reason}};
decode_payload(_, _, _) ->
    {error, invalid_payload}.

%%====================================================================
%% Message Handling
%%====================================================================

%% @doc Handle incoming circuit protocol message
%% Routes to appropriate handler based on message type
-spec handle_message(From :: node(), Msg :: binary(), State :: term()) ->
    {ok, Response :: term()} | {error, term()}.
handle_message(From, Msg, _State) ->
    case decode(Msg) of
        {ok, {create, CircuitId, EphPubKey}} ->
            mycelium_circuit_relay:handle_create(From, CircuitId, EphPubKey);
        {ok, {created, CircuitId, EphPubKey}} ->
            mycelium_circuit:handle_created(CircuitId, EphPubKey);
        {ok, {extend, CircuitId, {TargetNode, EphPubKey}}} ->
            mycelium_circuit_relay:handle_extend(From, CircuitId, TargetNode, EphPubKey);
        {ok, {extended, CircuitId, EphPubKey}} ->
            mycelium_circuit:handle_extended(CircuitId, EphPubKey);
        {ok, {data, CircuitId, EncryptedPayload}} ->
            handle_data(From, CircuitId, EncryptedPayload);
        {ok, {destroy, CircuitId, Reason}} ->
            handle_destroy(From, CircuitId, Reason);
        {error, _} = Error ->
            Error
    end.

%% @doc Handle DATA message - route based on whether we're relay or endpoint
handle_data(From, CircuitId, EncryptedPayload) ->
    case mycelium_circuit_relay:lookup(CircuitId) of
        {ok, Hop} ->
            %% We're a relay - forward the data
            NextNode = case From =:= Hop#circuit_hop.prev_node of
                true -> Hop#circuit_hop.next_node;
                false -> Hop#circuit_hop.prev_node
            end,
            case NextNode of
                destination ->
                    %% Forward to local circuit endpoint
                    mycelium_circuit:handle_data(CircuitId, EncryptedPayload);
                initiator ->
                    %% Forward to local circuit endpoint
                    mycelium_circuit:handle_data(CircuitId, EncryptedPayload);
                Node when is_atom(Node) ->
                    %% Forward to next hop
                    Msg = encode_data(CircuitId, EncryptedPayload),
                    mycelium_circuit_transport:send(Node, CircuitId, Msg),
                    ok
            end;
        {error, not_found} ->
            %% We're an endpoint - deliver to circuit process
            mycelium_circuit:handle_data(CircuitId, EncryptedPayload)
    end.

%% @doc Handle DESTROY message - propagate and cleanup
handle_destroy(From, CircuitId, Reason) ->
    case mycelium_circuit_relay:lookup(CircuitId) of
        {ok, Hop} ->
            %% We're a relay - propagate destroy to other side
            OtherNode = case From =:= Hop#circuit_hop.prev_node of
                true -> Hop#circuit_hop.next_node;
                false -> Hop#circuit_hop.prev_node
            end,
            mycelium_circuit_relay:remove(CircuitId),
            case OtherNode of
                destination -> ok;
                initiator -> ok;
                Node when is_atom(Node) ->
                    Msg = encode_destroy(CircuitId, Reason),
                    mycelium_circuit_transport:send(Node, CircuitId, Msg)
            end,
            ok;
        {error, not_found} ->
            %% We're an endpoint - notify circuit process
            mycelium_circuit:handle_destroy(CircuitId, Reason)
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

encode_circuit_id(#circuit_id{id = Id, initiator = Initiator}) ->
    InitBin = atom_to_binary(Initiator, utf8),
    InitLen = byte_size(InitBin),
    <<Id/binary, InitLen:8, InitBin/binary>>.

decode_circuit_id(<<Id:?CIRCUIT_ID_SIZE/binary, InitLen:8, InitBin:InitLen/binary>>) ->
    Initiator = binary_to_atom(InitBin, utf8),
    {ok, #circuit_id{id = Id, initiator = Initiator}};
decode_circuit_id(_) ->
    {error, invalid_circuit_id}.
