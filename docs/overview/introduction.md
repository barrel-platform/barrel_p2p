# Introduction

This is the longer companion to [What is barrel_p2p?](what-is-barrel_p2p.md).
It explains *why* each piece of the system is shaped the way it
is. Read this once; the per-concept pages then make sense without
context-switching.

## The problem

Erlang's default distribution is wonderful for what it was
designed to do: tightly couple a small set of nodes that trust
each other on a local network, and make `Pid ! Msg` work across
machines as if they were one.

It struggles outside that envelope. Three specific ways:

- **Full mesh.** Every node opens a TCP connection to every other
  node. Past a few dozen nodes, the connection count, the kernel
  resources, and the `nodeup`/`nodedown` event volume start to be
  expensive.
- **No identity layer.** The Erlang cookie is a shared secret;
  knowing the cookie is enough to join the cluster. There is no
  per-peer identity, no rotation, no revocation.
- **No service discovery.** `global` provides cluster-wide
  registration coordinated through a distributed
  consensus-but-not-quite, and it does not scale much past the
  full mesh.

Barrel P2P addresses all three, while preserving the property that
matters most: standard Erlang code paths still work. `Pid ! Msg`
is still the right way to send a message.

## The shape of the solution

Three subsystems, mostly independent of each other:

1. **The dist carrier**. A QUIC-based replacement for the TCP
   carrier, with Ed25519 mutual authentication slotted in between
   the QUIC TLS handshake and the Erlang dist handshake.
2. **The membership protocol**. HyParView keeps each node
   connected to a small, bounded set of gossip peers. The cluster
   stays fully reachable through OTP's demand-driven auto-connect.
3. **The service registry**. An Observed-Remove Map (OR-Map) CRDT
   replicated through Plumtree epidemic broadcast. Names are
   cluster-wide; eventual consistency, no coordination.

The rest of this introduction walks through each in turn, in
enough depth that the per-concept pages make sense.

## Layer one: the QUIC carrier

Why QUIC?

- **Encryption is mandatory.** Every Erlang dist byte rides on a
  TLS-protected QUIC connection. No mode where you accidentally
  ship cleartext over a hostile network.
- **One UDP socket per peer.** A single connection multiplexes
  the Erlang dist control stream plus any application streams
  (`barrel_p2p_streams`) plus the Ed25519 auth handshake. This is
  the natural shape for a P2P system.
- **Connection migration.** A QUIC connection can rebind to a
  new local 4-tuple without losing keys or streams. Useful when
  the local network changes (laptops, CGNAT shuffles, tunnel
  reconnects).

The carrier itself is upstream `quic_dist`. Barrel P2P is a thin
proto_dist shim on top: it auto-generates the self-signed TLS
material on first boot, projects the right defaults into the
`quic.dist` app env, and wires the Ed25519 callback. Everything
else delegates to upstream.

### Why Ed25519 on top of TLS

The QUIC TLS handshake gives us a confidential channel, but it
does not say *who* is on the other side. The certs are
self-signed; there is no authority barrel_p2p expects you to trust.

The Ed25519 layer adds that. Each node has a long-lived Ed25519
keypair stored on disk. The public key is the node's identity;
the private key is what the node uses to prove that identity.
Across TLS rotations, across reboots, the Ed25519 keypair
persists. Peers pin each other's public keys under the node
atom; subsequent handshakes verify the pinned key matches.

Two trust modes:

- **TOFU** (trust on first use): the first handshake records the
  peer's key. Subsequent handshakes verify the pin.
- **Strict**: every peer's key must be pre-pinned. No
  first-contact window.

The same mechanism powers SSH's `known_hosts`.

## Layer two: bounded membership

The HyParView protocol gives each node two sets:

- The **active view**, a small bounded set (default 5) of peers
  this node currently exchanges gossip with. Symmetric: if A has
  B in its active view, B has A in its active view.
- The **passive view**, a larger bounded cache (default 30) of
  known but disconnected peers, used as warm spares.

The key insight: the active view does **not** need to grow with
the cluster. The protocol guarantees that any peer is reachable
from any starting point by repeatedly forwarding through this
small bounded view. For a cluster of thousands of nodes, five
active links per node is enough.

When a peer fails, exponential backoff prevents reconnection
storms. After enough failures, the protocol promotes a peer from
the passive view to replace the failed one in the active view.

A periodic *shuffle* (every 10 seconds by default) exchanges a
small random sample of the active and passive views with one
active peer. That is how new members reach corners of the
cluster that did not see their initial join, and how the passive
view stays fresh enough that there is always a spare.

### Why this matters for `Pid ! Msg`

In the default Erlang dist, every node has a TCP connection to
every other node, so `Pid ! Msg` is always a no-op at the
connection level. In a partial-membership setting, two nodes that
have never met have no open connection between them.

Barrel P2P leans on OTP's demand-driven dist auto-connect. When
`Pid ! Msg` targets a node outside the active view, a fresh
QUIC channel opens on demand: TLS handshake, Ed25519 mutual auth,
Erlang dist handshake, and only then does the message flow. If
the channel is then idle for long enough, the dist GC reaps it.

The end result: from the application's perspective, sending to
any peer works. The connection count stays bounded.

![Sending a message to a pid on a node that is not in the local active view: OTP opens a QUIC dist channel on demand, runs Ed25519 auth, then delivers the message.](diagrams/message-passing.png)

## Layer three: the service registry

Names are stored in an Observed-Remove Map (OR-Map) CRDT. Three
properties matter:

- **Adds and removes commute.** Two concurrent adds of the same
  name produce two entries; removes only delete the dots they
  have observed.
- **Tombstones are bounded.** Old removes can be garbage
  collected once every node has observed them.
- **Causal merging.** Two replicas merge by union plus the rule
  that a tombstoned dot stays tombstoned.

Each registration carries a *dot*: a `{node, hlc_timestamp}`
pair. The hybrid logical clock guarantees that two registrations
from the same node are ordered, and two registrations from
different nodes can be compared causally.

Replication happens through Plumtree epidemic broadcast:

- Each broadcast goes to the *eager peers* in the active view
  first (full message body).
- Lazy peers receive only the message ID (`IHAVE` announcement).
- A duplicate triggers a `PRUNE` (the sender becomes lazy).
- A missing message triggers a `GRAFT` (the lazy peer is
  promoted back to eager).

The tree self-organises into a near-optimal spanning structure
for broadcasts and self-heals through `GRAFT` after peer
failures. The cost of a broadcast is `O(n)` messages, not
`O(n²)`.

## Putting it together

A real example: a registration on node A flows like this:

1. The application calls `register_service/2`. The local
   registry updates its OR-Map with a fresh dot.
2. The registry's `barrel_p2p_replica` instance produces a delta and
   broadcasts it through Plumtree.
3. Each eager peer receives the delta, merges into its OR-Map,
   and forwards to its own eager peers. Lazy peers receive an
   `IHAVE` and graft if they have not seen the message.
4. Within a fraction of a second, every node has the
   registration in its local OR-Map.
5. A `whereis_service/1` call on any node now finds the
   registration.

From the application's point of view, the call returned `ok` and
the name is "out there". The protocol does the work.

## Where to read next

If you want to skim:

- [What is barrel_p2p?](what-is-barrel_p2p.md) is the short version.
- [Benefits and trade-offs](benefits.md) tells you when to pick
  this and when not to.

If you want to start using it:

- [Getting started](getting-started.md).

If you want to dig into one piece at a time:

- [Cluster membership concept](../concepts/cluster-membership.md)
- [Service registry concept](../concepts/service-registry.md)
- [Gossip broadcast concept](../concepts/gossip-broadcast.md)
- [Dist channel concept](../concepts/dist-channel.md)
- [Authentication concept](../concepts/authentication.md)
- [Streams concept](../concepts/streams.md)
- [Connection migration concept](../concepts/connection-migration.md)
- [Hybrid logical clocks concept](../concepts/hybrid-logical-clocks.md)
