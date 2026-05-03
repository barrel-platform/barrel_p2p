%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-ifndef(MYCELIUM_HRL).
-define(MYCELIUM_HRL, true).

%% Peer representation (transport-agnostic)
-record(peer, {
    id            :: node(),                    %% Node name
    address       :: inet:ip_address() | undefined, %% IP address (for passive view)
    port          :: inet:port_number() | undefined, %% Distribution port
    quic_port     :: inet:port_number() | undefined, %% QUIC dist UDP port (when known)
    connected     :: boolean(),                 %% Currently in active view?
    priority      :: high | low,                %% For NEIGHBOR protocol
    last_seen     :: integer() | undefined,     %% erlang:monotonic_time()
    %% Failure tracking for high churn handling
    fail_count    = 0 :: non_neg_integer(),     %% Consecutive failures
    backoff_until :: integer() | undefined      %% erlang:monotonic_time() - skip until this time
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

%% Trusted peer key for Ed25519 authentication.
%% Identity is the public key fingerprint (SHA-256). The optional
%% `node' field is what the dist-key ETS store keys on while we still
%% bridge node-name -> key for the dist handshake.
-record(peer_key, {
    node        :: node() | undefined, %% Last-seen node name (ETS key)
    fingerprint :: binary() | undefined, %% SHA-256 hash of public key (32 bytes)
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

-endif.
