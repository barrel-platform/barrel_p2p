-ifndef(MYCELIUM_HRL).
-define(MYCELIUM_HRL, true).

%%====================================================================
%% NAT Types and Records
%%====================================================================

%% NAT type classification (RFC 5780)
-type nat_type() :: public           %% No NAT, directly reachable
                  | full_cone        %% Any external host can reach via mapped address
                  | restricted_cone  %% External host must receive packet first (IP restricted)
                  | port_restricted  %% External host must receive packet first (IP+port restricted)
                  | symmetric        %% Different mapping per destination
                  | unknown.         %% Could not determine

%% Connection candidate for NAT traversal (ICE-like)
-record(candidate, {
    type     :: host | srflx | relay,    %% host=local, srflx=STUN reflexive, relay=TURN
    address  :: inet:ip_address(),
    port     :: inet:port_number(),
    priority :: non_neg_integer()
}).

%% NAT info for cache storage
-record(nat_info, {
    nat_type      :: nat_type(),
    external_addr :: inet:ip_address() | undefined,
    external_port :: inet:port_number() | undefined,
    candidates    :: [#candidate{}],
    discovered_at :: integer(),          %% erlang:monotonic_time(millisecond)
    expires_at    :: integer()           %% erlang:monotonic_time(millisecond)
}).

%% Peer representation (transport-agnostic)
-record(peer, {
    id            :: node(),                    %% Node name
    address       :: inet:ip_address() | undefined, %% IP address (for passive view)
    port          :: inet:port_number() | undefined, %% Distribution port
    connected     :: boolean(),                 %% Currently in active view?
    priority      :: high | low,                %% For NEIGHBOR protocol
    last_seen     :: integer() | undefined,     %% erlang:monotonic_time()
    %% Failure tracking for high churn handling
    fail_count    = 0 :: non_neg_integer(),     %% Consecutive failures
    backoff_until :: integer() | undefined,     %% erlang:monotonic_time() - skip until this time
    %% NAT fields (Phase 2)
    nat_type      :: nat_type() | undefined,
    external_addr :: inet:ip_address() | undefined,
    external_port :: inet:port_number() | undefined,
    candidates    :: [#candidate{}] | undefined
}).

%% HyParView state (application layer)
-record(view_state, {
    %% Parameters
    active_size    = 5  :: pos_integer(),    %% Max active view (log n)
    passive_size   = 30 :: pos_integer(),    %% Max passive view (c * log n)
    arwl           = 6  :: pos_integer(),    %% Active Random Walk Length
    prwl           = 3  :: pos_integer(),    %% Passive Random Walk Length
    shuffle_length = 8  :: pos_integer(),    %% Nodes per shuffle
    shuffle_period = 10000 :: pos_integer(), %% Shuffle interval (ms)

    %% Views
    active_view  = #{} :: #{node() => #peer{}},  %% Connected peers
    passive_view = #{} :: #{node() => #peer{}},  %% Known but not connected

    %% Pending operations
    pending = #{} :: #{node() => {atom(), reference()}},

    %% Self
    self :: #peer{},

    %% Churn handling parameters
    max_fail_count = 5 :: pos_integer(),        %% Max failures before removal
    base_backoff_ms = 1000 :: pos_integer(),    %% Base backoff interval (ms)
    passive_max_age_ms = 300000 :: pos_integer(), %% Max age for passive entries (5 min)

    %% Churn tracking for adaptive shuffle
    recent_joins = 0 :: non_neg_integer(),      %% Joins in current window
    recent_leaves = 0 :: non_neg_integer(),     %% Leaves in current window
    churn_window_start :: integer() | undefined, %% Window start time
    churn_window_ms = 30000 :: pos_integer()    %% Churn tracking window (30s)
}).

%% Service registry entry
%% Note: version removed - OR-Map CRDT handles conflict resolution via HLC dots
-record(service_entry, {
    name    :: atom() | binary(),
    pid     :: pid(),
    node    :: node(),
    meta    = #{} :: map()
}).

%% Routing request for overlay lookup
-record(route_req, {
    service_name :: atom() | binary(),   %% Service to find
    ttl = 5 :: non_neg_integer(),        %% Max hops remaining
    origin :: node(),                     %% Node that initiated the request
    visited = [] :: [node()]             %% Nodes already visited
}).

%% Trusted peer key for Ed25519 authentication
%% Identity is based on key fingerprint (SHA-256 hash), not node name
-record(peer_key, {
    fingerprint :: binary(),        %% SHA-256 hash of public key (32 bytes)
    public_key  :: binary(),        %% 32 bytes Ed25519 public key
    added_at    :: integer(),       %% erlang:system_time(millisecond)
    last_seen   :: integer(),       %% erlang:system_time(millisecond)
    trust_level :: permanent | tofu %% permanent = pre-configured, tofu = trust on first use
}).

%% Crypto session state for encrypted distribution
-record(crypto_session, {
    send_key    :: binary(),           %% 32 bytes ChaCha20 key for sending
    recv_key    :: binary(),           %% 32 bytes ChaCha20 key for receiving
    send_nonce  :: non_neg_integer(),  %% Counter for send nonce
    recv_nonce  :: non_neg_integer()   %% Counter for receive nonce
}).

%% HyParView protocol messages (sent over Erlang distribution)
-type hyparview_msg() ::
    {join, Sender :: #peer{}} |
    {forward_join, NewPeer :: #peer{}, TTL :: integer(), Sender :: #peer{}} |
    {disconnect, Sender :: #peer{}} |
    {neighbor, Priority :: high | low, Sender :: #peer{}} |
    {neighbor_reply, Accept :: boolean(), Sender :: #peer{}} |
    {shuffle, TTL :: integer(), Peers :: [#peer{}], Sender :: #peer{}} |
    {shuffle_reply, Peers :: [#peer{}], Sender :: #peer{}}.

%%====================================================================
%% Circuit Routing Records
%%====================================================================

%% Circuit identifier
-record(circuit_id, {
    id        :: binary(),       %% 16 bytes UUID
    initiator :: node()
}).

%% Relay hop state (held by intermediate nodes)
-record(circuit_hop, {
    circuit_id :: #circuit_id{},
    prev_node  :: node() | initiator,
    next_node  :: node() | destination,
    created_at :: integer(),
    last_seen  :: integer()
}).

%% Full circuit state (endpoint only - initiator or destination)
-record(circuit, {
    id         :: #circuit_id{},
    role       :: initiator | destination,
    target     :: node(),
    hops       :: [node()],
    crypto     :: #crypto_session{},
    state      :: building | ready | closing,
    created_at :: integer(),
    expires_at :: integer()
}).

%% Circuit protocol message types
-define(CIRCUIT_CREATE, 1).
-define(CIRCUIT_CREATED, 2).
-define(CIRCUIT_EXTEND, 3).
-define(CIRCUIT_EXTENDED, 4).
-define(CIRCUIT_DATA, 5).
-define(CIRCUIT_DESTROY, 6).
-define(CIRCUIT_PING, 7).
-define(CIRCUIT_PONG, 8).

%% Hole punch signaling message types (sent via relay)
-define(HOLE_PUNCH_REQUEST, 16).
-define(HOLE_PUNCH_RESPONSE, 17).
-define(HOLE_PUNCH_CONNECT, 18).
-define(HOLE_PUNCH_CONNECTED, 19).

-endif.
