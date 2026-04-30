%%% -*- erlang -*-
%%%
%%% Mycelium Distribution Records and Constants
%%% Erlang Distribution over QUIC, owned by mycelium.
%%%
%%% Adapted from erlang_quic's quic_dist.hrl
%%% (Apache 2.0, Copyright (c) 2024-2026 Benoit Chesneau).
%%%

-ifndef(MYCELIUM_DIST_HRL).
-define(MYCELIUM_DIST_HRL, true).

%%====================================================================
%% Distribution Constants
%%====================================================================

%% ALPN protocol identifier for mycelium distribution
-define(MYCELIUM_DIST_ALPN, <<"mycelium-dist">>).

%% Stream types

% Stream 0: Control (handshake, tick, signals)
-define(MYCELIUM_DIST_CONTROL_STREAM, 0).
% Streams 4,8,12... for data messages
-define(MYCELIUM_DIST_DATA_STREAM_BASE, 4).

%% Stream urgency levels (RFC 9218)

% Auth stream - even higher than control during handshake
-define(MYCELIUM_DIST_URGENCY_AUTH, 0).
% Control stream - top dist priority
-define(MYCELIUM_DIST_URGENCY_CONTROL, 0).
% Link/monitor signals
-define(MYCELIUM_DIST_URGENCY_SIGNAL, 2).
% High priority data
-define(MYCELIUM_DIST_URGENCY_DATA_HIGH, 4).
% Normal data messages
-define(MYCELIUM_DIST_URGENCY_DATA_NORMAL, 5).
% Low priority data
-define(MYCELIUM_DIST_URGENCY_DATA_LOW, 6).

%% Default number of data streams
-define(MYCELIUM_DIST_DATA_STREAMS, 4).

%% Message length prefixes

% 2-byte length prefix during handshake
-define(MYCELIUM_DIST_HS_LEN_SIZE, 2).
% 4-byte length prefix post-handshake
-define(MYCELIUM_DIST_MSG_LEN_SIZE, 4).

%% Tick interval (milliseconds)
-define(MYCELIUM_DIST_TICK_INTERVAL, 60000).

%% Control message types (1-byte tag, sent on control stream only)
-define(MYCELIUM_DIST_MSG_TICK, 1).
-define(MYCELIUM_DIST_MSG_TICK_ACK, 2).

%% Idle timeout for distribution connections (5 minutes)
-define(MYCELIUM_DIST_IDLE_TIMEOUT, 300000).

%% Keep-alive interval (150 seconds = half of idle timeout)
-define(MYCELIUM_DIST_KEEP_ALIVE_INTERVAL, 150000).

%% Distribution backpressure thresholds
-define(MYCELIUM_DEFAULT_QUEUE_CONGESTION_THRESHOLD, 2).
-define(MYCELIUM_DEFAULT_MAX_PULL_PER_NOTIFICATION, 16).
-define(MYCELIUM_DEFAULT_BACKPRESSURE_RETRY_MS, 10).

%% Default ports
-define(MYCELIUM_DIST_DEFAULT_PORT, 4433).
-define(MYCELIUM_DIST_PORT_RANGE_START, 4433).
-define(MYCELIUM_DIST_PORT_RANGE_END, 4532).

%%====================================================================
%% Controller States
%%====================================================================

-define(MYCELIUM_DIST_STATE_INIT, init).
-define(MYCELIUM_DIST_STATE_AUTHING, authing).
-define(MYCELIUM_DIST_STATE_HANDSHAKING, handshaking).
-define(MYCELIUM_DIST_STATE_CONNECTED, connected).
-define(MYCELIUM_DIST_STATE_DRAINING, draining).

%%====================================================================
%% Records
%%====================================================================

%% Distribution configuration from vm.args or sys.config
-record(mycelium_dist_config, {
    %% TLS certificate/key
    cert_file :: binary() | undefined,
    key_file :: binary() | undefined,
    cacert_file :: binary() | undefined,
    cert :: binary() | undefined,
    key :: term() | undefined,
    cacert :: binary() | undefined,
    verify = verify_none :: verify_none | verify_peer,

    %% Discovery
    discovery_module = mycelium_quic_discovery :: module(),
    nodes = [] :: [{node(), {inet:ip_address() | string(), inet:port_number()}}],
    dns_domain :: binary() | undefined,

    %% Load balancer
    lb_enabled = false :: boolean(),
    lb_server_id = auto :: auto | binary(),
    lb_key :: binary() | undefined,

    %% Backpressure tuning
    congestion_threshold = ?MYCELIUM_DEFAULT_QUEUE_CONGESTION_THRESHOLD :: pos_integer(),
    max_pull_per_notification = ?MYCELIUM_DEFAULT_MAX_PULL_PER_NOTIFICATION :: pos_integer(),
    backpressure_retry_ms = ?MYCELIUM_DEFAULT_BACKPRESSURE_RETRY_MS :: pos_integer(),

    %% Pacing
    pacing_enabled = true :: boolean(),

    %% Auth (Ed25519 fingerprint identity, Phase 3)
    auth_enabled = true :: boolean(),
    auth_mode = tofu :: tofu | strict
}).

%% Listener state
-record(mycelium_dist_listener, {
    server_name :: atom(),
    port :: inet:port_number(),
    acceptor :: pid() | undefined,
    config :: #mycelium_dist_config{}
}).

%% Connection controller state
-record(mycelium_dist_conn, {
    %% Connection identity (Conn is the connection pid, receives {quic, Conn, Event} messages)
    conn :: pid(),
    node :: node() | undefined,
    role :: client | server,

    %% Streams
    control_stream :: non_neg_integer() | undefined,
    data_streams = [] :: [non_neg_integer()],
    next_data_stream_idx = 0 :: non_neg_integer(),

    %% Buffers (for partial message reassembly)
    recv_buffer = <<>> :: binary(),
    recv_expected = 0 :: non_neg_integer(),

    %% State tracking
    handshake_complete = false :: boolean(),
    tick_pending = false :: boolean(),
    last_tick :: non_neg_integer() | undefined,

    %% Distribution protocol callbacks
    f_send :: fun((term()) -> ok | {error, term()}) | undefined,
    f_recv ::
        fun((non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, term()})
        | undefined,

    %% Session ticket for 0-RTT
    session_ticket :: term() | undefined
}).

%% Handshake data for dist_util
-record(mycelium_hs_data, {
    kernel_pid :: pid(),
    other_node :: node(),
    this_node :: node(),
    socket :: term(),
    timer :: reference() | undefined,
    this_flags :: integer(),
    other_flags :: integer(),
    other_version :: integer(),
    f_send :: function(),
    f_recv :: function(),
    f_setopts_pre_nodeup :: function(),
    f_setopts_post_nodeup :: function(),
    f_getll :: function(),
    f_address :: function(),
    mf_tick :: function(),
    mf_getstat :: function(),
    request_type :: atom(),
    mf_setopts :: function(),
    mf_getopts :: function()
}).

%% Stream data message wrapper
-record(mycelium_dist_msg, {
    stream_id :: non_neg_integer(),
    data :: binary(),
    fin = false :: boolean()
}).

%%====================================================================
%% User Stream Support
%%====================================================================

%% Reserved stream ranges - distribution uses 0 (control), 4,8,12,16
%% (client data), 1,5,9,13 (server data). User streams start above.

% Client-initiated user streams start at 20
-define(MYCELIUM_USER_STREAM_THRESHOLD_CLIENT, 20).
% Server-initiated user streams start at 17
-define(MYCELIUM_USER_STREAM_THRESHOLD_SERVER, 17).

%% Application error code for refused streams (no acceptor available)
-define(MYCELIUM_STREAM_REFUSED, 16#100).

%% User stream priority constraints
-define(MYCELIUM_USER_STREAM_MIN_PRIORITY, 16).
-define(MYCELIUM_USER_STREAM_DEFAULT_PRIORITY, 128).

%% User stream state record
-record(mycelium_user_stream, {
    id :: non_neg_integer(),
    owner :: pid(),
    monitor :: reference(),
    %% Stream priority (16=highest user, 255=lowest)
    priority = ?MYCELIUM_USER_STREAM_DEFAULT_PRIORITY :: 16..255,
    recv_fin = false :: boolean(),
    send_fin = false :: boolean()
}).

% MYCELIUM_DIST_HRL
-endif.
