# Connection Migration

Mycelium runs on `quic_dist`, so each peer is a single QUIC connection
under the dist channel. RFC 9000 §9 lets a QUIC connection rebind to
a new local UDP 4-tuple (e.g. when the local NIC, IP, or default route
changes) without losing keys, streams, or ordering. Mycelium exposes
that as a one-shot trigger; deciding *when* to migrate is left to the
caller.

This is unrelated to the multi-hop **circuit** migration described in
[circuits.md](circuits.md), which handles intermediate-hop failure on
top of multiple connections.

## API

```erlang
%% Trigger path migration to a new local 4-tuple.
ok                     = mycelium:migrate_peer(Node).
ok                     = mycelium:migrate_peer(Node, #{timeout => 5000}).

%% Common error returns:
{error, not_connected}        %% no current dist channel to Node
{error, no_conn}              %% controller alive but conn pid gone
{error, peer_disable_migration} %% peer set the transport-param flag
{error, timeout}              %% path validation didn't complete
```

`migrate_peer/1,2` is synchronous — it blocks until path validation
completes (or the configured timeout elapses, default 5000 ms). On
success the dist channel and any open circuits ride through with no
app-visible interruption and no HyParView churn.

## Custom triggers

Mycelium does not run an automatic migration policy. A custom
trigger is an external process or module that decides when to call
`migrate_peer/1`. The pieces it needs are already public:

- `mycelium_hyparview_events:subscribe/1` — `peer_up`/`peer_down`
  notifications, so the trigger knows the active view.
- `mycelium_path_stats:srtt/1` and `summary/1` — current QUIC path
  stats per peer (srtt, latest_rtt, cwnd, in_flight, congested).
- `mycelium:migrate_peer/1,2` — the trigger itself.

### Recipe: srtt-threshold watchdog

A minimal watchdog that migrates any peer whose smoothed RTT exceeds
a threshold for two consecutive samples:

```erlang
-module(my_migration_watchdog).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SAMPLE_MS, 5000).
-define(THRESHOLD_US, 200000).   %% 200 ms

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    ok = mycelium:subscribe(),                  %% peer_up/peer_down
    erlang:send_after(?SAMPLE_MS, self(), tick),
    {ok, #{strikes => #{}}}.

handle_info(tick, #{strikes := Strikes} = S) ->
    NewStrikes = lists:foldl(fun sample/2, Strikes, mycelium:active_view()),
    erlang:send_after(?SAMPLE_MS, self(), tick),
    {noreply, S#{strikes := NewStrikes}};
handle_info({peer_down, Node}, #{strikes := Strikes} = S) ->
    {noreply, S#{strikes := maps:remove(Node, Strikes)}};
handle_info(_, S) -> {noreply, S}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S)    -> {noreply, S}.

sample(Node, Strikes) ->
    case mycelium_path_stats:srtt(Node) of
        {ok, Us} when Us > ?THRESHOLD_US ->
            case maps:get(Node, Strikes, 0) of
                N when N >= 1 ->
                    spawn(fun() -> mycelium:migrate_peer(Node) end),
                    maps:remove(Node, Strikes);
                N ->
                    Strikes#{Node => N + 1}
            end;
        _ ->
            maps:remove(Node, Strikes)
    end.
```

Two design notes:

- **Don't block the watchdog on `migrate_peer/1`.** Path validation
  takes up to the configured timeout. Spawn the call so the timer
  cadence stays steady.
- **Remember `peer_disable_migration`.** It's a static transport
  parameter — once you see it, retries on the same connection will
  always return the same error. Cache it and skip that peer until
  HyParView reports `peer_down`/`peer_up`.

### Other trigger sources

Whatever signals a network change in your environment can drive the
same call:

- `inet`/`net_kernel` netlink-style events (Linux) on default-route
  flip.
- Custom `os:cmd("scutil ...")` / `SCNetworkReachability` poll on
  macOS.
- An MDM/management agent telling the node "you're now on cellular".
- A user-space VPN/tunnel daemon that just rebound its local socket.

In all cases the trigger code is the same one-line call to
`mycelium:migrate_peer(Node)`.

## When migration fails

`{error, peer_disable_migration}` is terminal for the connection;
typically you let HyParView demote and re-route at its own cadence.

`{error, timeout}` means the new path didn't validate in time —
either the route is genuinely broken (HyParView will eventually
notice and demote) or simply slow. Retrying with a larger timeout is
fine; the connection stays usable on the old path while validation is
in flight.

`{error, not_connected}` and `{error, no_conn}` mean there is no
QUIC connection to migrate — the peer is gone or the dist channel
hasn't formed yet. Wait for `peer_up`.
