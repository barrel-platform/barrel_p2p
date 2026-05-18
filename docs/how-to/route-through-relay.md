# Running mycelium dist over an external relay

Mycelium assumes nodes can reach each other directly. The
codebase contains no NAT traversal, no UDP hole punching, and no
firewall-bypass logic. When two peers cannot route to each other
directly, the recommended path is to send the dist UDP traffic
through an **external relay** that you already trust to handle
the traversal: a forwarding proxy, a MASQUE CONNECT-UDP gateway,
a WireGuard tunnel, an SSH `ProxyCommand`, or any other transport
your environment provides.

This document describes the seam the upstream
[`quic_dist`](https://github.com/benoitc/erlang_quic) layer
exposes for that purpose and gives one worked example. The
mycelium-specific work is small; most of the integration lives
outside this codebase.

## The seam: per-node connect-time overrides

Mycelium's distribution layer is `quic_dist`. Before opening a
QUIC connection to a peer, `quic_dist:setup/5` consults a small
ETS table of per-node overrides:

```erlang
quic_dist:set_connect_options(Node, Opts).
quic_dist:get_connect_options(Node).
quic_dist:clear_connect_options(Node).
```

`Opts` is a map merged on top of the defaults `quic_dist` would
otherwise use for the connection. It is consumed *once*: the next
`setup/5` against the same node sees no override unless you set
it again. This makes the seam easy to compose with a supervisor
that re-registers the override after every reconnect, and
straightforward to use for one-shot operations.

The two keys that matter for a relay:

```erlang
#{
  socket_backend => adapter,
  socket_adapter => Adapter
}
```

`Adapter` is a map describing a custom datagram transport that
`erlang_quic` will use instead of opening a real UDP socket. The
upstream `quic_socket.erl` documents the callbacks; at a high
level you provide functions for `open/1`, `send/4`, and an event
stream that hands inbound datagrams back to QUIC.

Because the QUIC handshake, the Ed25519 auth callback, and the
Erlang dist handshake all run on top of whatever socket the
adapter exposes, no other code in mycelium needs to know about
the relay. The adapter looks like a UDP socket to everything
above it.

## A worked example

Route a single peer through a hypothetical MASQUE-style relay:

```erlang
ok = quic_dist:set_connect_options('peer@remote', #{
    socket_backend => adapter,
    socket_adapter => my_relay_adapter:new(#{
        proxy  => <<"https://proxy.example.com/connect-udp/">>,
        target => {<<"remote">>, 4433},
        token  => os:getenv("RELAY_TOKEN")
    })
}),

%% This call uses the relay. Subsequent reconnects without a
%% fresh set_connect_options would fall back to a direct
%% connection (which would fail in this scenario).
true = net_kernel:connect_node('peer@remote').
```

`my_relay_adapter` is your module: it implements the `quic_socket`
adapter contract for whatever protocol your relay speaks. Mycelium
does not ship one. The protocol-specific work, including
authentication against the relay and re-handshake on tunnel
disconnect, lives in your adapter.

For long-lived static routing (always relay this peer), put the
`set_connect_options` call in a small supervisor that
re-registers on every `{nodedown, 'peer@remote'}` event.

## Migrating between relays

QUIC connection migration lets an established session move to a
different UDP path without renegotiating keys or losing streams.
The same `mycelium:migrate_peer/1,2` primitive that handles
local-network changes also handles relay swaps:

1. Establish a new socket adapter pointing at the new relay path
   (whatever "new relay path" means in your protocol).
2. Call `mycelium:migrate_peer(Node, #{timeout => 5000})` to
   migrate the running connection.
3. After migration succeeds, the dist controller continues
   sending on the new path.

See [migration.md](migrate-connections.md) for the migration primitive and
a watchdog recipe.

## What mycelium does not do

It is worth being explicit about what is *not* part of the
mycelium codebase:

- No STUN.
- No UPnP/NAT-PMP/PCP discovery.
- No ICE-style candidate gathering.
- No UDP hole punching.
- No automatic "direct first, then relay" fallback.

The decision of when to relay and when to go direct is the
operator's. Mycelium provides the seam; you provide the policy.

If you need any of these, run them out of process: a sidecar
daemon, a MASQUE proxy, a tailscale-style mesh. Present the
result as an adapter through the seam above. The dividing line
keeps the codebase small and keeps the protocol-specific
complexity outside the dist channel itself.
