# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-05-03

First public release.

### Membership and replication
- HyParView partial-view membership (active/passive views, ARWL/PRWL,
  shuffle, neighbor swap, age-based passive cleanup, churn handling).
- Plumtree epidemic broadcast tree (eager/lazy push, ihave/graft/prune,
  self-healing).
- Service registry on an Observed-Remove Map CRDT, replicated through
  Plumtree, with overlay-routed `whereis_service`, local-pid proxies
  for remote services, and `peer_up`/`peer_down` event subscription.
- Hybrid Logical Clocks for causally-ordered timestamps used by the
  CRDT and routing layers.

### Distribution carrier
- Runs on upstream `quic_dist` (`-proto_dist quic`); one QUIC
  connection per peer carries the Erlang dist channel.
- EPMD-less by default via upstream's `quic_epmd` lookup module.
- Composing discovery chain (`mycelium_discovery`) with three
  built-in backends: static config (`mycelium_discovery_static`),
  on-disk file registry for local auto-discovery
  (`mycelium_discovery_file`), and DNS host fallback
  (`mycelium_discovery_dns`).
- Plugs into upstream's `auth_callback` extension point via
  `mycelium_dist_auth_callback`.
- Ed25519 distribution authentication: TOFU and strict trust modes,
  fingerprint-keyed trust store on disk, `cookie_only_nodes`
  whitelist for c-nodes that can't speak the auth protocol.
- `mycelium_dist_keys:fingerprint/1` SHA-256 helper for diagnostics.

### Streams and circuits
- Tagged user-stream multiplex (`mycelium_streams`): single acceptor
  per node, demultiplexes by `<<TagLen:8, Tag/binary>>` preamble;
  reserved tag `<<"mycelium:circuit">>`, free tag space for apps.
- Multi-hop circuits (`mycelium_circuit`): stream-shaped channels
  between cluster nodes that aren't in each other's active view,
  spliced at intermediate hops with stateless relays.
- Byte-perfect migration across hop failure: 48-bit per-direction
  frame sequence numbers, cumulative ACKs, symmetric `FRAME_RESUME`
  exchange that prunes unacked buffers and replays preserving
  DATA/FIN frame type. No data loss on relay disappearance.

### Observability and routing
- RTT-aware path selection (`mycelium_router:find_path/1,2`) using
  `quic:get_path_stats/1` (upstream) for srtt-based hop ranking.
- `mycelium_path_stats` wrapper exposing `summary/1`, `srtt/1`, and
  `connection/1` (resolves a peer node to the underlying QUIC pid).

### Connection migration
- `mycelium:migrate_peer/1,2` triggers RFC 9000 §9 path migration on
  the per-peer dist channel; rebinds to a new local 4-tuple without
  rekey or HyParView churn. Custom triggers (NIC-change, path-quality
  thresholds, etc.) live in app code via the public events + stats +
  this API; recipe in `docs/migration.md`.

### Pluggable transport overrides
- `quic_dist:set_connect_options/2` is the seam for routing a peer
  through an out-of-tree relay/tunnel adapter (MASQUE, WireGuard,
  SSH ProxyCommand, etc.). Documented in `docs/external-relay.md`.

### Tooling
- `priv/bin/mycelium_call.sh` — `erl_call`-style one-shot RPC helper
  that boots a hidden probe with full Ed25519 identity and runs
  `rpc:call/5` against a live mycelium node. Available to anything
  depending on mycelium via `_build/default/lib/mycelium/priv/bin/`.

### Tests
- Eunit (72 cases) covering circuit framing, reliability link, stream
  multiplex, path stats, router path selection, dist-key fingerprint,
  and migrate_peer wrapper.
- Common Test (177 cases) covering churn, registry, plumtree, hyparview,
  failure handling, dist-auth, and the basic two/three-node cluster
  mechanics suites.
- `mycelium_circuit_multinode_SUITE` — gated four-node diamond
  topology integration suite driven via upstream `quic_call.sh`
  (`MYCELIUM_CT_QUIC_MULTINODE=1`).
- GitHub Actions matrix CI on OTP 27 and 28: compile, xref, dialyzer,
  eunit, ct, plus the multi-node job.
- Dialyzer- and xref-clean.

### Documentation
- README, `docs/getting-started.md`, `docs/tutorial.md`,
  `docs/internals.md`, `docs/circuits.md`, `docs/migration.md`,
  `docs/authentication.md`, `docs/external-relay.md`,
  `docs/testing.md`, `docs/partisan-comparison.md`.
- LICENSE (Apache-2.0), SECURITY.md.
