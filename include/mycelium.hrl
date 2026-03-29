-ifndef(MYCELIUM_HRL).
-define(MYCELIUM_HRL, true).

%% Peer representation (transport-agnostic)
-record(peer, {
    id        :: node(),                    %% Node name
    address   :: inet:ip_address(),         %% IP address (for passive view)
    port      :: inet:port_number(),        %% Distribution port
    connected :: boolean(),                 %% Currently in active view?
    priority  :: high | low,                %% For NEIGHBOR protocol
    last_seen :: integer() | undefined      %% erlang:monotonic_time()
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
    self :: #peer{}
}).

%% Service registry entry
-record(service_entry, {
    name    :: atom() | binary(),
    pid     :: pid(),
    node    :: node(),
    version :: pos_integer(),           %% For LWW conflict resolution
    meta    = #{} :: map()
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
