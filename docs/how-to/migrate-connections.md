# Connection migration

Barrel P2P runs the Erlang distribution channel on a single QUIC
connection per peer. QUIC supports connection migration: an
established session can rebind to a new local UDP 4-tuple without
losing keys, ordering, or streams. RFC 9000 §9 specifies the
mechanism; barrel_p2p exposes it as a one-shot trigger.

This document covers when migration is useful, how to call it,
and a small watchdog recipe for driving it from an application.

## What migration solves

Three motivating cases:

- A laptop running barrel_p2p moves from Wi-Fi to a wired link, or
  from one Wi-Fi network to another, or from Wi-Fi to a cellular
  uplink. The local IP changes; the peer expects packets on the
  old 4-tuple.
- A server's outbound IP changes because of a CGNAT shuffle, a
  routing-table change, or a NIC swap. The peer holds a
  connection that is now silently dead.
- A user-space tunnel (WireGuard, MASQUE, an SSH `ProxyCommand`)
  reconnects and exposes a new local socket.

In each case the alternatives are unsatisfactory: closing and
re-establishing the dist channel triggers HyParView churn,
flushes any in-flight Erlang dist data, and (with strict trust
mode) requires a full re-handshake. Migration moves the session
to the new path in milliseconds, with no observable interruption
in the Erlang layer.

Migration is *not* something barrel_p2p does on its own. It is an
application-driven trigger: you decide when the local network has
changed enough to warrant a path validation.

## The API

```erlang
ok                              = barrel_p2p:migrate_peer(Node).
ok                              = barrel_p2p:migrate_peer(Node, #{timeout => 5000}).

%% Errors:
{error, not_connected}          %% no current dist channel to Node
{error, no_conn}                %% controller alive but QUIC conn gone
{error, peer_disable_migration} %% peer set the transport-param flag
{error, timeout}                %% path validation didn't complete in time
```

The call is synchronous. It blocks until the new path is
validated by the QUIC layer (the PATH_CHALLENGE / PATH_RESPONSE
exchange) or until the timeout fires. The default timeout is
5000 ms.

On success the dist channel and any open user streams ride
through; the application does not see an interruption.

## Error semantics

A short note on each error.

- `{error, not_connected}` and `{error, no_conn}` mean there is
  nothing to migrate. The dist channel does not exist or has
  already gone away. Wait for `peer_up` and try again.
- `{error, peer_disable_migration}` is **terminal for the
  connection**. The peer set the QUIC
  `disable_active_migration` transport parameter at handshake
  time; no migration on this connection will ever succeed.
  Cache this fact and skip the peer until HyParView reports
  `peer_down`/`peer_up`. Retrying on the same connection wastes
  time.
- `{error, timeout}` means the new path did not validate within
  the budget. Either the new route is genuinely broken (in
  which case HyParView will notice the failure and demote the
  peer at its own cadence), or it is simply slow. Retrying
  with a larger timeout is fine; the old path remains usable
  while the new path is being validated.

## Writing a trigger

Barrel P2P does not run an automatic migration policy. The
deliberate choice: deciding "the network has changed" depends on
your environment (mobile device, container with a CGNAT, custom
tunnel), and a one-size-fits-all heuristic would be wrong for
half of them.

The pieces you need are already public:

- `barrel_p2p:subscribe/0` produces `peer_up` / `peer_down` events,
  so a trigger knows the current active view.
- `barrel_p2p_path_stats:srtt/1` returns the smoothed RTT for a
  peer's underlying QUIC path.
- `barrel_p2p_path_stats:summary/1` returns a richer snapshot
  (srtt, latest_rtt, cwnd, in_flight, congested).
- `barrel_p2p:migrate_peer/1,2` is the trigger.

### Recipe: srtt-threshold watchdog

The simplest useful trigger samples each active peer's SRTT
periodically and migrates a peer whose SRTT exceeds a threshold
on two consecutive samples:

```erlang
-module(my_migration_watchdog).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SAMPLE_MS, 5000).
-define(THRESHOLD_US, 200000).   %% 200 ms

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    ok = barrel_p2p:subscribe(),
    erlang:send_after(?SAMPLE_MS, self(), tick),
    {ok, #{strikes => #{}}}.

handle_info(tick, #{strikes := Strikes} = S) ->
    NewStrikes = lists:foldl(fun sample/2, Strikes, barrel_p2p:active_view()),
    erlang:send_after(?SAMPLE_MS, self(), tick),
    {noreply, S#{strikes := NewStrikes}};

handle_info({barrel_p2p_event, {peer_down, Node, _}}, #{strikes := Strikes} = S) ->
    {noreply, S#{strikes := maps:remove(Node, Strikes)}};

handle_info(_, S) ->
    {noreply, S}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S)    -> {noreply, S}.

sample(Node, Strikes) ->
    case barrel_p2p_path_stats:srtt(Node) of
        {ok, Us} when Us > ?THRESHOLD_US ->
            case maps:get(Node, Strikes, 0) of
                N when N >= 1 ->
                    %% Spawn so we do not block the watchdog tick on
                    %% the synchronous migrate call.
                    spawn(fun() -> barrel_p2p:migrate_peer(Node) end),
                    maps:remove(Node, Strikes);
                N ->
                    Strikes#{Node => N + 1}
            end;
        _ ->
            maps:remove(Node, Strikes)
    end.
```

Two design points worth keeping in your own watchdog:

- **Do not block the trigger on `migrate_peer/1`.** Path
  validation can take up to the configured timeout (default
  5000 ms). Spawn the call so the sample cadence stays steady.
- **Cache `peer_disable_migration`.** Once a peer returns it,
  retries on the same connection will always return the same
  error. Skip the peer until you see `peer_down`/`peer_up`.

### Other trigger sources

Anything that signals a local network change can drive the same
call:

- Linux `inet`/`netlink` events on default-route flip.
- macOS `SCNetworkReachability` notifications.
- A user-space VPN/tunnel daemon that just rebound its local
  socket.
- An MDM agent telling the node "you're now on cellular".
- A docker network reconfiguration.

In each case the trigger code is the same one-line call to
`barrel_p2p:migrate_peer(Node)`. The trigger itself is your code
and your decision.

## Multi-peer migration

Migrating only one peer is the common case (one peer is on a new
route; the others remain reachable). If your local network change
affects many or all peers, iterate:

```erlang
[ spawn(fun() -> barrel_p2p:migrate_peer(N) end)
  || N <- barrel_p2p:active_view() ].
```

Spawning per call keeps the trigger from serialising on a slow
peer's timeout.

## Interaction with relays

If you are routing some peers through an external relay (see
[external-relay.md](route-through-relay.md)), the same migration
primitive applies: register a new socket adapter pointing at the
new relay path, then call `barrel_p2p:migrate_peer/1,2`. The
running QUIC connection migrates to the new path; the dist
controller continues sending on the new adapter.

This is how a relay swap can be done without dropping any
in-flight dist traffic.
