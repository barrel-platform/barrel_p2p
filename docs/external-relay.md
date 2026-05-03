# Running mycelium dist over an external relay

Mycelium assumes nodes can reach each other directly. There is no NAT
traversal, UDP hole punching, or firewall-bypass logic in the codebase.
When a peer is not directly reachable, the recommended path is to send
the dist UDP packets through an **external relay** that you already
trust to handle traversal: a forwarding proxy, a MASQUE
CONNECT-UDP gateway, a WireGuard tunnel, an SSH `ProxyCommand`, etc.

This document describes the seam upstream `quic_dist` exposes for that
purpose and gives one full worked example.

## The seam: per-node connect option overrides

Mycelium's distribution layer is upstream
[`quic_dist`](https://github.com/benoitc/erlang_quic). Before opening
an outgoing dist connection, `quic_dist:setup/5` takes a snapshot of
any per-node connect-time overrides registered via:

```erlang
quic_dist:set_connect_options(Node, Opts).
quic_dist:get_connect_options(Node).
quic_dist:clear_connect_options(Node).
```

`Opts` is a map merged on top of the defaults that `quic_dist` builds
for the QUIC connection. It is consumed once; the next `setup/5`
attempt against `Node` clears it.

Two keys are relevant for relayed traffic:

```erlang
#{
  socket_backend => adapter,
  socket_adapter => Adapter
}
```

`Adapter` is a map describing a custom datagram transport that
`erlang_quic` will use instead of opening a real UDP socket. The
adapter callbacks are documented in `quic_socket.erl` (upstream); at a
high level you provide functions for `open/1`, `send/4`, and an event
stream that hands inbound datagrams back to QUIC.

Because the QUIC handshake, the Ed25519 auth callback, and the Erlang
dist handshake all run on top of whatever socket the adapter exposes,
no other code in mycelium needs to know about the relay.

## Worked example: route a single peer through a MASQUE proxy

```erlang
ok = quic_dist:set_connect_options('peer@remote', #{
    socket_backend => adapter,
    socket_adapter => masque_adapter:new(#{
        proxy   => <<"https://proxy.example.com/connect-udp/">>,
        target  => {<<"remote">>, 4433},
        token   => os:getenv("MASQUE_TOKEN")
    })
}),
%% This call uses the relay; subsequent reconnects fall back to direct.
true = net_kernel:connect_node('peer@remote').
```

`masque_adapter` is whatever module implements the upstream
`quic_socket` adapter contract for your relay protocol. Mycelium does
not ship one; the protocol-specific work lives outside this codebase.

For long-lived static routing (always relay this peer), wrap the call
in your own supervisor that re-registers the override on every
`{nodedown, 'peer@remote'}` event.

## Connection migration via the same seam

QUIC's connection migration moves an established session to a new UDP
4-tuple without renegotiating. To migrate to a different relay:

1. Establish a new socket adapter pointing at the new path.
2. Tell the running QUIC connection to migrate. This is a `quic`
   primitive (`quic:migrate/2`), not a dist API; it operates on the
   connection ref returned by `quic_dist_controller:get_connection/1`
   for `'peer@remote'`.
3. Once migration completes, the dist controller continues sending on
   the new path.

Migration during a live session is the upstream's responsibility;
mycelium does not abstract it. See the upstream `quic` docs for the
concrete primitives.

## What mycelium does not do

* No STUN, no UPnP/NAT-PMP, no NAT-PMP/PCP discovery.
* No ICE-style candidate gathering.
* No UDP hole punching.
* No automatic "direct fail then relay" fallback. The decision is
  the operator's: register an override or do not.

If you need any of these, run them out of process (a sidecar daemon, a
MASQUE proxy, a tailscale-style mesh) and present the result as an
adapter through the seam above.
