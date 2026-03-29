-module(mycelium_circuit).
-behaviour(gen_statem).

%% Circuit endpoint state machine
%%
%% Manages a circuit from the perspective of an endpoint (initiator or destination).
%% Handles the create/extend handshake and data transmission.
%%
%% States: building -> ready -> closing
%%
%% For initiator:
%%   1. CREATE sent to first hop
%%   2. EXTEND sent through relays to reach destination
%%   3. EXTENDED received - circuit ready
%%
%% For destination:
%%   1. CREATE received - generate keys, send CREATED
%%   2. Circuit ready

-include("mycelium.hrl").

%% API
-export([
    start_link/6,
    start_link/5,
    create/2,
    send/2,
    close/1,
    get_info/1,
    get_info_by_pid/1
]).

%% Callbacks from protocol handler
-export([
    handle_created/2,
    handle_extended/2,
    handle_data/2,
    handle_destroy/2
]).

%% Destination-side API
-export([
    accept/3
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    building/3,
    ready/3,
    closing/3,
    terminate/3
]).

-record(data, {
    id              :: #circuit_id{},
    role            :: initiator | destination,
    target          :: node(),
    hops            :: [node()],
    pending_hops    :: [node()],
    crypto          :: #crypto_session{} | undefined,
    eph_keypair     :: {binary(), binary()} | undefined, %% {PubKey, PrivKey}
    owner           :: pid(),
    created_at      :: integer(),
    expires_at      :: integer(),
    establish_timer :: reference() | undefined,
    pending_reply   :: term() | undefined,
    first_node      :: node() | undefined  %% First hop node for transport registration
}).

-define(ESTABLISH_TIMEOUT, 30000).  %% 30 seconds to establish circuit
-define(DEFAULT_TTL, 3600000).      %% 1 hour default TTL

%%====================================================================
%% API
%%====================================================================

%% @doc Start circuit as initiator (called by supervisor)
-spec start_link(initiator, CircuitId :: #circuit_id{}, Target :: node(),
                 Hops :: [node()], TTL :: pos_integer(), Owner :: pid()) ->
    {ok, pid()} | {error, term()}.
start_link(initiator, CircuitId, Target, Hops, TTL, Owner) ->
    gen_statem:start_link(?MODULE, {initiator, CircuitId, Target, Hops, TTL, Owner}, []).

%% @doc Start circuit as destination (called by supervisor)
-spec start_link(destination, CircuitId :: #circuit_id{}, CryptoSession :: #crypto_session{},
                 TTL :: pos_integer(), Owner :: pid()) ->
    {ok, pid()} | {error, term()}.
start_link(destination, CircuitId, CryptoSession, TTL, Owner) ->
    gen_statem:start_link(?MODULE, {destination, CircuitId, CryptoSession, TTL, Owner}, []).

%% @doc Create a new circuit to target node
%% Options:
%%   hops => integer() - number of intermediate hops (default: 2)
%%   ttl => integer() - circuit lifetime in ms (default: 1 hour)
-spec create(Target :: node(), Opts :: map()) ->
    {ok, CircuitId :: #circuit_id{}} | {error, term()}.
create(Target, Opts) ->
    case Target =:= node() of
        true ->
            {error, cannot_circuit_to_self};
        false ->
            NumHops = maps:get(hops, Opts, get_default_hops()),
            TTL = maps:get(ttl, Opts, get_default_ttl()),

            %% Select random hops from active/passive view
            case select_hops(Target, NumHops) of
                {ok, Hops} ->
                    %% Generate circuit ID
                    Id = crypto:strong_rand_bytes(16),
                    CircuitId = #circuit_id{id = Id, initiator = node()},

                    %% Start the circuit process
                    case mycelium_circuit_sup:start_circuit(CircuitId, initiator, Target, Hops, TTL, self()) of
                        {ok, _Pid} ->
                            {ok, CircuitId};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

%% @doc Send data through circuit
-spec send(CircuitId :: #circuit_id{}, Data :: binary()) -> ok | {error, term()}.
send(CircuitId, Data) when is_binary(Data) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:call(Pid, {send, Data});
        {error, _} = Error ->
            Error
    end.

%% @doc Close circuit
-spec close(CircuitId :: #circuit_id{}) -> ok.
close(CircuitId) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:cast(Pid, close);
        {error, not_found} ->
            ok
    end.

%% @doc Get circuit info
-spec get_info(CircuitId :: #circuit_id{}) -> {ok, map()} | {error, not_found}.
get_info(CircuitId) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:call(Pid, get_info);
        {error, _} = Error ->
            Error
    end.

%% @doc Get circuit info by pid (for list_circuits)
-spec get_info_by_pid(pid()) -> {ok, map()} | {error, term()}.
get_info_by_pid(Pid) ->
    try
        gen_statem:call(Pid, get_info, 1000)
    catch
        _:_ -> {error, not_available}
    end.

%%====================================================================
%% Protocol Callbacks
%%====================================================================

%% @doc Handle CREATED response from first hop
handle_created(CircuitId, EphPubKey) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:cast(Pid, {created, EphPubKey});
        {error, not_found} ->
            ok
    end.

%% @doc Handle EXTENDED response - circuit fully established
handle_extended(CircuitId, EphPubKey) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:cast(Pid, {extended, EphPubKey});
        {error, not_found} ->
            ok
    end.

%% @doc Handle incoming DATA
handle_data(CircuitId, EncryptedPayload) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:cast(Pid, {data, EncryptedPayload});
        {error, not_found} ->
            ok
    end.

%% @doc Handle DESTROY from remote
handle_destroy(CircuitId, Reason) ->
    case find_circuit(CircuitId) of
        {ok, Pid} ->
            gen_statem:cast(Pid, {destroy, Reason});
        {error, not_found} ->
            ok
    end.

%%====================================================================
%% Destination API
%%====================================================================

%% @doc Accept incoming circuit (called when CREATE received at destination)
-spec accept(CircuitId :: #circuit_id{}, InitiatorEphPub :: binary(), OwnerPid :: pid()) ->
    {ok, pid()} | {error, term()}.
accept(CircuitId, InitiatorEphPub, OwnerPid) ->
    %% Generate our keypair
    {PubKey, PrivKey} = mycelium_crypto:generate_ephemeral_keypair(),

    %% Compute shared secret and derive session keys
    SharedSecret = mycelium_crypto:compute_shared_secret(InitiatorEphPub, PrivKey),
    {_InitiatorSession, DestSession} = mycelium_crypto:derive_session_keys(
        SharedSecret, InitiatorEphPub, PubKey
    ),

    %% Start circuit process as destination
    TTL = get_default_ttl(),
    case mycelium_circuit_sup:start_circuit_dest(CircuitId, DestSession, TTL, OwnerPid) of
        {ok, Pid} ->
            %% Send CREATED back
            Reply = mycelium_circuit_protocol:encode_created(CircuitId, PubKey),
            send_backward(CircuitId, Reply),
            {ok, Pid};
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() -> state_functions.

%% Called by supervisor for initiator role
init({initiator, CircuitId, Target, Hops, TTL, Owner}) ->
    Now = erlang:monotonic_time(millisecond),
    ExpiresAt = Now + TTL,

    %% Record metrics
    mycelium_circuit_metrics:circuit_created(initiator),

    %% Generate ephemeral keypair for E2E encryption with destination
    {PubKey, PrivKey} = mycelium_crypto:generate_ephemeral_keypair(),

    %% Register circuit in local registry
    register_circuit(CircuitId, self()),

    %% Set establishment timeout
    TimerRef = erlang:send_after(?ESTABLISH_TIMEOUT, self(), establish_timeout),

    %% Determine first node for transport
    FirstNode = case Hops of
        [] -> Target;
        [FirstHop | _] -> FirstHop
    end,

    Data = #data{
        id = CircuitId,
        role = initiator,
        target = Target,
        hops = Hops,
        pending_hops = Hops,
        eph_keypair = {PubKey, PrivKey},
        owner = Owner,
        created_at = Now,
        expires_at = ExpiresAt,
        establish_timer = TimerRef,
        first_node = FirstNode
    },

    %% Send CREATE to first hop (or directly to target if no hops)
    CreateMsg = mycelium_circuit_protocol:encode_create(CircuitId, PubKey),
    mycelium_circuit_transport:send(FirstNode, CircuitId, CreateMsg),

    %% Register with transport for failure notifications
    mycelium_circuit_transport:register_circuit(FirstNode, CircuitId, self()),

    {ok, building, Data};

%% Called by supervisor for destination role
init({destination, CircuitId, CryptoSession, TTL, Owner}) ->
    Now = erlang:monotonic_time(millisecond),
    ExpiresAt = Now + TTL,

    %% Record metrics (destination circuits are immediately ready)
    mycelium_circuit_metrics:circuit_created(destination),
    mycelium_circuit_metrics:circuit_established(destination, 0),

    %% Register circuit in local registry
    register_circuit(CircuitId, self()),

    %% Set expiry timer
    TimeRemaining = ExpiresAt - Now,
    erlang:send_after(TimeRemaining, self(), expired),

    %% The "first node" for destination is the previous hop (relay or initiator)
    %% We get this from the connection that delivered the CREATE message
    %% For now, we use the initiator as a fallback (works for direct circuits)
    FirstNode = CircuitId#circuit_id.initiator,

    Data = #data{
        id = CircuitId,
        role = destination,
        target = CircuitId#circuit_id.initiator,
        hops = [],
        pending_hops = [],
        crypto = CryptoSession,
        owner = Owner,
        created_at = Now,
        expires_at = ExpiresAt,
        first_node = FirstNode
    },

    %% Register with transport for failure notifications
    mycelium_circuit_transport:register_circuit(FirstNode, CircuitId, self()),

    %% Notify owner circuit is ready
    Owner ! {circuit_ready, CircuitId},

    {ok, ready, Data}.

%%====================================================================
%% State: building
%%====================================================================

building(cast, {created, EphPubKey}, Data) ->
    %% First relay acknowledged - now extend to remaining hops or target
    case Data#data.pending_hops of
        [] ->
            %% No more hops - compute crypto session and go ready
            finalize_circuit(EphPubKey, Data);
        [_CurrentHop | RemainingHops] ->
            %% Extend to next hop or target
            NextTarget = case RemainingHops of
                [] -> Data#data.target;
                [NextHop | _] -> NextHop
            end,
            {PubKey, _} = Data#data.eph_keypair,
            ExtendMsg = mycelium_circuit_protocol:encode_extend(
                Data#data.id, NextTarget, PubKey
            ),
            send_forward(Data, ExtendMsg),
            {next_state, building, Data#data{pending_hops = RemainingHops}}
    end;

building(cast, {extended, EphPubKey}, Data) ->
    %% Target responded - circuit complete
    finalize_circuit(EphPubKey, Data);

building(cast, {destroy, Reason}, Data) ->
    cancel_timer(Data#data.establish_timer),
    mycelium_circuit_metrics:circuit_failed({destroyed, Reason}),
    Data#data.owner ! {circuit_failed, Data#data.id, {destroyed, Reason}},
    {stop, normal};

building(info, establish_timeout, Data) ->
    mycelium_circuit_metrics:circuit_failed(timeout),
    Data#data.owner ! {circuit_failed, Data#data.id, timeout},
    %% Send destroy to cleanup partial circuit
    send_destroy(Data, 1),
    {stop, normal};

building(info, {transport_down, _Node, Reason}, Data) ->
    cancel_timer(Data#data.establish_timer),
    mycelium_circuit_metrics:circuit_failed({transport_down, Reason}),
    Data#data.owner ! {circuit_failed, Data#data.id, {transport_down, Reason}},
    {stop, normal};

building({call, From}, get_info, Data) ->
    Info = build_info(Data, building),
    {keep_state, Data, [{reply, From, {ok, Info}}]};

building({call, From}, {send, _Payload}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, circuit_not_ready}}]};

building(cast, close, Data) ->
    cancel_timer(Data#data.establish_timer),
    mycelium_circuit_metrics:circuit_failed(local_close),
    send_destroy(Data, 0),
    {stop, normal}.

%%====================================================================
%% State: ready
%%====================================================================

ready({call, From}, {send, Payload}, Data) ->
    case mycelium_crypto:encrypt(Payload, Data#data.crypto, <<>>) of
        {ok, Encrypted, NewCrypto} ->
            DataMsg = mycelium_circuit_protocol:encode_data(Data#data.id, Encrypted),
            send_forward(Data, DataMsg),
            mycelium_circuit_metrics:data_sent(byte_size(Payload)),
            {keep_state, Data#data{crypto = NewCrypto}, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

ready(cast, {data, EncryptedPayload}, Data) ->
    case mycelium_crypto:decrypt(EncryptedPayload, Data#data.crypto, <<>>) of
        {ok, Plaintext, NewCrypto} ->
            mycelium_circuit_metrics:data_received(byte_size(Plaintext)),
            Data#data.owner ! {circuit_data, Data#data.id, Plaintext},
            {keep_state, Data#data{crypto = NewCrypto}};
        {error, _Reason} ->
            %% Decryption failure - destroy circuit
            send_destroy(Data, 2),
            mycelium_circuit_metrics:circuit_closed(decrypt_failed),
            Data#data.owner ! {circuit_closed, Data#data.id, decrypt_failed},
            {stop, normal}
    end;

ready(cast, {destroy, Reason}, Data) ->
    mycelium_circuit_metrics:circuit_closed({remote, Reason}),
    Data#data.owner ! {circuit_closed, Data#data.id, {remote, Reason}},
    {stop, normal};

ready(cast, close, Data) ->
    send_destroy(Data, 0),
    mycelium_circuit_metrics:circuit_closed(local),
    Data#data.owner ! {circuit_closed, Data#data.id, local},
    {stop, normal};

ready({call, From}, get_info, Data) ->
    Info = build_info(Data, ready),
    {keep_state_and_data, [{reply, From, {ok, Info}}]};

ready(info, expired, Data) ->
    send_destroy(Data, 1),
    mycelium_circuit_metrics:circuit_closed(expired),
    Data#data.owner ! {circuit_closed, Data#data.id, expired},
    {stop, normal};

ready(info, {transport_down, _Node, Reason}, Data) ->
    %% Transport connection failed - circuit is broken
    %% No need to send DESTROY (transport is down)
    mycelium_circuit_metrics:circuit_closed({transport_down, Reason}),
    Data#data.owner ! {circuit_closed, Data#data.id, {transport_down, Reason}},
    {stop, normal}.

%%====================================================================
%% State: closing
%%====================================================================

closing(cast, {destroy, _Reason}, _Data) ->
    {stop, normal};

closing(info, close_timeout, _Data) ->
    {stop, normal};

closing(_, _, _Data) ->
    keep_state_and_data.

%%====================================================================
%% terminate
%%====================================================================

terminate(_Reason, _State, Data) ->
    %% Unregister from local circuit registry
    unregister_circuit(Data#data.id),
    %% Unregister from transport (so connection can be closed if last circuit)
    case Data#data.first_node of
        undefined -> ok;
        FirstNode ->
            mycelium_circuit_transport:unregister_circuit(FirstNode, Data#data.id)
    end,
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

finalize_circuit(EphPubKey, Data) ->
    cancel_timer(Data#data.establish_timer),

    %% Compute shared secret and derive session keys
    {_PubKey, PrivKey} = Data#data.eph_keypair,
    SharedSecret = mycelium_crypto:compute_shared_secret(EphPubKey, PrivKey),

    {OurPubKey, _} = Data#data.eph_keypair,
    {InitiatorSession, _DestSession} = mycelium_crypto:derive_session_keys(
        SharedSecret, OurPubKey, EphPubKey
    ),

    %% Set expiry timer
    Now = erlang:monotonic_time(millisecond),
    TimeRemaining = Data#data.expires_at - Now,
    erlang:send_after(TimeRemaining, self(), expired),

    %% Record establishment latency
    LatencyMs = Now - Data#data.created_at,
    mycelium_circuit_metrics:circuit_established(initiator, LatencyMs),

    %% Notify owner
    Data#data.owner ! {circuit_ready, Data#data.id},

    {next_state, ready, Data#data{
        crypto = InitiatorSession,
        eph_keypair = undefined,
        pending_hops = []
    }}.

select_hops(_Target, NumHops) when NumHops =< 0 ->
    {ok, []};
select_hops(Target, NumHops) ->
    %% Prefer direct route if target is a direct neighbor
    ActiveView = mycelium_hyparview:active_view(),
    case lists:member(Target, ActiveView) of
        true ->
            %% Target is a direct neighbor, no intermediate hops needed
            {ok, []};
        false ->
            select_intermediate_hops(Target, NumHops, ActiveView)
    end.

select_intermediate_hops(Target, NumHops, ActiveView) ->
    %% Prefer active peers for hops (direct neighbors)
    AvailableActive = [P || P <- ActiveView, P =/= Target],
    case length(AvailableActive) >= NumHops of
        true ->
            %% Shuffle and take required number
            Shuffled = shuffle_list(AvailableActive),
            {ok, lists:sublist(Shuffled, NumHops)};
        false ->
            %% Need more peers from passive view
            case mycelium_hyparview:passive_view() of
                PassivePeers when length(PassivePeers) + length(AvailableActive) >= NumHops ->
                    AvailablePassive = [P || P <- PassivePeers, P =/= Target],
                    AllPeers = AvailableActive ++ shuffle_list(AvailablePassive),
                    {ok, lists:sublist(AllPeers, NumHops)};
                _ ->
                    {error, not_enough_peers}
            end
    end.

shuffle_list(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- List])].

get_default_hops() ->
    application:get_env(mycelium, circuit_default_hops, 2).

get_default_ttl() ->
    application:get_env(mycelium, circuit_default_ttl, ?DEFAULT_TTL).

send_forward(Data, Msg) ->
    %% Send toward target (through hops if any)
    Node = case Data#data.hops of
        [] -> Data#data.target;
        [FirstHop | _] -> FirstHop
    end,
    mycelium_circuit_transport:send(Node, Data#data.id, Msg).

send_backward(CircuitId, Msg) ->
    %% Send back toward initiator
    mycelium_circuit_transport:send(CircuitId#circuit_id.initiator, CircuitId, Msg).

send_destroy(Data, Reason) ->
    DestroyMsg = mycelium_circuit_protocol:encode_destroy(Data#data.id, Reason),
    send_forward(Data, DestroyMsg).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).

build_info(Data, State) ->
    #{
        id => Data#data.id,
        role => Data#data.role,
        target => Data#data.target,
        hops => Data#data.hops,
        state => State,
        created_at => Data#data.created_at,
        expires_at => Data#data.expires_at
    }.

%% Circuit registry (simple process dictionary for now, could be ETS)
register_circuit(CircuitId, Pid) ->
    ets:insert(mycelium_circuits, {circuit_key(CircuitId), Pid}).

unregister_circuit(CircuitId) ->
    ets:delete(mycelium_circuits, circuit_key(CircuitId)).

find_circuit(CircuitId) ->
    try
        case ets:lookup(mycelium_circuits, circuit_key(CircuitId)) of
            [{_, Pid}] -> {ok, Pid};
            [] -> {error, not_found}
        end
    catch
        error:badarg -> {error, not_found}
    end.

circuit_key(#circuit_id{id = Id, initiator = Initiator}) ->
    {Id, Initiator}.
