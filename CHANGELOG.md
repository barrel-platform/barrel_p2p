# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to the 0.x semantics described in the README
(a minor bump may break).

## [Unreleased]

### Security
- A peer could connect under another node's name. The name proven by the
  Ed25519 handshake was never compared with the node a client dialed, nor
  with the name the peer then used in the Erlang dist handshake. With the
  default trust-on-first-use mode and the default cookie, anyone could
  join a cluster under a known node's name; in strict mode, one stolen
  node key was enough to impersonate every node. Clients now refuse a
  server that authenticates as a node other than the one they dialed. The
  server-side check needs a quic release that enforces the authenticated
  name, and will follow.
- A node's handshake signatures did not say which side produced them, so
  a signature made in one role passed in the other. An attacker could make
  a node accept itself as a peer, or impersonate a node to a client that
  reached the attacker's endpoint, using a signature that node made while
  connecting to the attacker. Signatures now cover the whole handshake
  (both names, both keys, both nonces) with the signer's role.

### Fixed
- After two nodes started campaigning for the same leadership at the same
  time, the winner could keep a fencing token lower than one the loser had
  already issued. A resource checking tokens would then refuse every write
  from the real leader. The leader now takes a new, higher token when it
  sees a higher one, and its owner receives `{elected, Fence}` again.
- A broadcast could miss a node for good after a single link failure: a
  node remembered only the first peer that offered a missing message, and
  if that link failed it never asked the others. It now asks each in turn.
- Broadcasts were dropped silently on a busy connection. They now wait for
  the connection instead.
- A peer that had left the membership view could keep receiving every
  broadcast, if one of its messages arrived just after it left.
- The membership layer crashed whenever it promoted a spare peer to
  replace a lost one, which happens on every eviction and every failed
  link. The membership process restarted with empty views, so the node
  briefly lost its place in the overlay.
- Membership links could exist on one side only: a node that accepted a
  newcomer added it, but the newcomer never added the node back. Gossip
  then flowed in one direction on that link. Links are now always set up
  on both ends, and spare peers taking over a lost link are announced to
  the rest of the node (gossip and replication) like any other link.
- Leaving the cluster (`barrel_p2p:leave/0`) did not tell the node's own
  gossip layer, which kept sending to peers it had left. A node that had
  left could also be pulled straight back in by a peer looking for a
  replacement link; it now stays out until it joins again.
- A spare peer that could not be reached was silently forgotten instead of
  being retried later with a backoff, so the pool of spares shrank with
  every failed attempt. Spare entries also never expired because of a time
  unit mismatch.
- A removal could be lost on a peer after a network partition healed: the
  resync skipped any node whose data held only removals. A stopped service
  could stay listed, a resigned leader candidate could stay a candidate, a
  removed map key could stay on that peer, and a cancelled or already
  fired reminder could fire again there. Removals are now always part of
  the resync.
- The service registry could keep listing an unregistered service on a
  peer after a partition, because the registry's own copy of a write
  carried an older timestamp than the copy it sent to peers. Every
  replicated service now sends a write exactly as it stored it.

### Added
- A TLA+ model of the replication layer, checked in CI. It proves that
  the registry, leader election and replicated maps converge after any
  partition within the model's bounds, and it found the bugs above. See
  the Verification page in the docs.
- `barrel_p2p_replica:broadcast_entry/3` and `broadcast_delta/2` for
  custom replicated stores: gossip a write exactly as it was stored.

### Changed
- A replicated entry now remembers only its latest write instead of every
  write it ever had. Replicas that saw the same writes now hold exactly the
  same state, not just the same visible value. Entries from nodes on the
  previous version are converted on arrival, so mixed clusters keep
  converging.
- Replicated maps with `prune_on_peer_down` now drop a key when its latest
  write came from the node that left. Before, a key was dropped only if
  that node had made every write to it.

### Breaking
- The distribution auth handshake is now protocol version 3. Nodes on
  version 2 are refused at the first message, so upgrade every node of a
  cluster together.
- Erlang/OTP 29 or later is now required. Support for OTP 27 and 28 is
  dropped, along with the fallback certificate encoding those releases
  needed.

### Changed
- quic 1.8.1 -> 2.6.1 and instrument 1.1.0 -> 2.0.0. No barrel_p2p code
  change. quic 2.x brings in webtransport, h2 and hackney as new transitive
  dependencies.
- instrument 2.0.0 builds cleanly on OTP 29, so the dependency override
  that silenced its deprecated `catch` warnings is gone.
- Test and tooling: proper 1.4.0 -> 1.5.0, rebar3_lint 5 -> 6, erlfmt
  1.7 -> 1.8.
- quic 1.4.2 -> 1.8.1. Brings client certificate verification and the
  security hardening from 1.4.4 (CVE-2026-49457), IPv6 and Happy Eyeballs
  client connections, 0-RTT, stateless reset on restart, mutual TLS with
  `require_client_cert`, and post-quantum `x25519mlkem768` key exchange.
  No barrel_p2p code change: the `{quic, Conn, _}` owner events and the
  `quic_dist` / `quic_epmd` functions used here are unchanged.
- Erlang/OTP 29 support. The bare `catch` operator is deprecated in OTP 29
  and the project builds with `warnings_as_errors`; every bare `catch` in
  src and test is now `try ... catch`, or plain return-value handling where
  the call cannot raise (`file:close/1`, `disk_log:close/1`). Argument
  parsing in `barrel_p2p_dist` uses `string:to_integer/1` instead of
  `catch list_to_integer/1`.
- CI tests OTP 29 with rebar3 3.27.0.
- Test profile: meck 0.9.2 -> 1.2.0 (older meck does not compile on
  OTP 29).
- Dropped the now-unused elvis `no_catch_expressions` ignore list.

## [0.1.0] - 2026-05-26

First public release. Barrel P2P is an enhancement to Erlang distribution:
a `proto_dist` module over QUIC with HyParView membership, Plumtree gossip,
a CRDT service registry, and Ed25519 peer authentication, while keeping
`Pid ! Msg`, `gen_server`, `rpc`, `global`, links, and monitors working
normally.

### Membership and gossip
- HyParView partial-view membership: bounded active/passive views, ARWL/PRWL
  forwarding, shuffle, neighbor swap, age-based passive cleanup, churn
  handling, and a backstop timer (`pending_timeout_ms`, default 30s) so a peer
  that goes silent mid-handshake never leaks a pending entry.
- Plumtree epidemic broadcast: eager/lazy push with ihave/graft/prune and
  self-healing; peers are removed from both eager and lazy sets on `peer_down`.
- Membership event subscription: `barrel_p2p:subscribe/0,1`, `unsubscribe/1`
  deliver `{barrel_p2p_event, {peer_up, Node} | {peer_down, Node, Reason}}`.

### Distribution carrier
- `-proto_dist barrel_p2p`: a transparent boot shim over upstream `quic_dist`.
  One QUIC connection per peer carries the Erlang dist channel, multiplexed
  across a pool of streams (the control stream is prioritised). Three vm.args
  flags select it; certificate paths, the auth callback, and discovery are
  projected into `quic_dist` automatically.
- Dist channels are decoupled from the HyParView active view: `Pid ! Msg`
  works between any cluster members via OTP's demand-driven auto-connect,
  resolved through the discovery chain. The active view tracks only the
  bounded gossip topology.
- EPMD-less by default (`barrel_p2p_epmd`).
- Composing discovery chain (`barrel_p2p_discovery`): static config
  (`barrel_p2p_discovery_static`), a shared on-disk registry
  (`barrel_p2p_discovery_file`), and DNS host fallback
  (`barrel_p2p_discovery_dns`).
- Config-driven seeding: `contact_nodes` auto-joins the listed seeds at boot
  (`barrel_p2p_bootstrap`), retrying every `contact_retry_ms` (default 5000)
  until the node is in the overlay, with no manual `barrel_p2p:join/1`.
- Idle dist-channel GC (`barrel_p2p_dist_gc`): an always-on reaper that drops
  channels not in the active view, carrying no live user stream, and aged
  past `dist_gc_min_age_ms`.
- Connection migration: `barrel_p2p:migrate_peer/1,2` triggers RFC 9000 §9 path
  migration on a peer's dist channel, rebinding to a new local 4-tuple without
  rekey or HyParView churn.
- Pluggable transport seam: `quic_dist:set_connect_options/2` routes a peer
  through an out-of-tree relay/tunnel adapter (MASQUE, WireGuard, SSH
  ProxyCommand). Experimental; no committed adapter.

### Authentication and identity
- Ed25519 mutual authentication after the QUIC TLS handshake and before the
  Erlang dist handshake. The signed message is bound to the QUIC TLS channel
  (a SHA-256 of the server cert) and to the responder's own public key, so a
  relayed handshake lands on a different cert and fails: this closes an
  on-path MITM in both trust modes. Wire protocol v2.
- TOFU (default) and strict trust modes; a pinned node is rejected if it
  presents a different key in either mode (no silent re-pin). Fingerprint-keyed
  trust store on disk; `cookie_only_nodes` whitelist for probes that cannot
  speak the auth protocol (symmetric check).
- The dist handshake carries the claimed node name as a binary and mints the
  atom only after the signature verifies, closing an atom-table exhaustion DoS
  reachable before authentication. Names are format- and length-validated
  (255-byte cap, `name@host` shape, restricted charset).
- Self-signed QUIC TLS cert is ECDSA P-256 with `notBefore` backdated for peer
  clock skew, a CSPRNG 127-bit serial, and GeneralizedTime encoding for
  validity years >= 2050.
- Secret material (`node.key`, trust-store pins) is written through
  `barrel_p2p_file:write_secure/2`: chmod 0600 before any plaintext byte, then
  atomic rename. The keypair is consistency-checked on load
  (`{error, keypair_mismatch}` rather than using mismatched material).
- Boot guards: `auth_enabled` defaults to `true`; boot warns on the default
  cookie, on `auth_enabled = false`, and on accepting a cookie-only peer, and
  refuses to start when `cookie_only_nodes` is set with the default cookie or
  when `auth_enabled = true` with an `undefined` auth callback.
- Handshake enforces a wall deadline across all recv sites; the replay-window
  check is responder-side monotonic with a cross-host wall-clock sanity bound,
  so an NTP step mid-handshake cannot spuriously fail.
- `barrel_p2p_rotate:rotate_cert/0,1` and `rotate_identity/0,1`: atomic backup
  under `<dir>/backups/<UTC-timestamp>/`. Identity rotation takes effect on the
  next handshake; cert rotation requires a restart.

### Service registry
- CRDT (Observed-Remove Map) registry replicated through the gossip layer:
  `register_service/1,2,3`, `unregister_service/1`, `lookup/1`,
  `lookup_local/1`, `list_services/0`, `whereis_service/1,2` with overlay-routed
  fallback, and local-pid proxies for remote services.
- OTP `via` callbacks (`{via, barrel_p2p, Name}`), `global_register/1`, and
  `get_proxy/1`.
- Service events: `subscribe_services/0,1`, `unsubscribe_services/1` deliver
  `{barrel_p2p_service_event, {service_registered | service_unregistered, Name,
  Node} | {service_down, Name, Node, Reason}}`.
- Overlay routing is bounded: `barrel_p2p_router` caps concurrent in-flight
  handlers (`router_max_in_flight`, default 256; over-cap replies
  `{error, overloaded}`), relays carry a TTL and visited list to prevent
  ping-pong, and a periodic sweep (`route_cache_sweep_period_ms`) evicts stale
  cache entries. `barrel_p2p_service_proxy` bounds overlay casts
  (`proxy_cast_max_in_flight`, default 32) and reaps dead remote proxies.

### Replicated state and coordination
- `barrel_p2p_replica`: a public behaviour for replicated state with custom
  merge or snapshot semantics. Gossiped OR-Map deltas, full-sync on `peer_up`,
  prune on `peer_down`, and seed-from-active-view plus pull-on-start so an
  instance created after the cluster formed recovers existing state. Callbacks
  take the instance name first, so one module backs many named instances.
  Periodic anti-entropy (`replica_anti_entropy_ms`, default 30000, `0`
  disables) reconverges value-carrying stores after a partition heal even
  without a fresh `peer_up`.
- `barrel_p2p_crdt_wire`: supported helper for safe gossip ingest (wrapper
  validation plus an optional leaf check; guards non-map payloads). The
  registry, leader, shard, and reminder validate incoming gossip before
  merging.
- `barrel_p2p_map`: replicated last-write-wins maps for small cluster-wide
  control-plane state. `new_map/1,2`, `delete_map/1`, `map_put/3`,
  `map_remove/2`, `map_get/2`, `map_keys/1`, `map_to_list/1`,
  `subscribe_map/1,2`, `unsubscribe_map/1,2`. One owner gen_server per map with
  a lock-free ETS read cache; per-map `validator`, `tombstone_ttl_ms`,
  `scan_ms`, `prune_on_peer_down`, and opt-in `persist => true`. Beta.
- Durable reminders (`barrel_p2p_reminder`): `remind/3`, `remind_after/3`,
  `cancel_reminder/1`, `subscribe_reminders/0,1`. Replicated, disk-persisted,
  fire-at-most-once timers that survive the node that armed them; the owner is
  `barrel_p2p:place/1`, so a survivor fires after the owner dies. Delivery is
  `{barrel_p2p_reminder, Key, Payload, Fence}` with a stable fence for idempotent
  dedup. Beta.
- Sharded placement (`barrel_p2p_shard`): `place/1`, `owners/2`, `is_owner/1`,
  `partition/1`, `members/0`, `subscribe_shard/0,1`. Rendezvous (HRW) hashing
  over a replicated, lease-based live-node set (periodic heartbeats), bucketed
  into `ring_size` partitions; owners react to
  `{barrel_p2p_shard, {acquired | released, Partition}}`. Beta.
- Leader election / singletons (`barrel_p2p_leader`): `lead/1,2`, `resign/1`,
  `leader/1`, `is_leader/1`, `fence/1`. A process campaigns for a named
  singleton and is notified with `{barrel_p2p_leader, Name, {elected, Fence} |
  revoked}`; the cluster elects one leader (highest priority, ties to lowest
  node atom) and re-elects on churn. Each term carries an HLC fencing token,
  strictly monotonic within a connected partition. Beta.
- Disk persistence (`barrel_p2p_replica_log`): a write-ahead log plus periodic
  snapshots, recovered on boot. Durable reminders survive a full-cluster
  restart (a `remind`/`cancel` is flushed before it returns); maps opt in with
  `persist => true`. Persisted values must be restart-safe data (no
  pids/ports/refs/funs). Config: `reminder_data_dir`, `barrel_p2p_map_data_dir`.
- Hybrid Logical Clocks (`barrel_p2p_hlc`) for causally-ordered timestamps used
  by the CRDT and coordination layers.

### Streams
- Tagged user-stream multiplex (`barrel_p2p_streams`): one acceptor per tag,
  demultiplexed by a `<<TagLen:8, Tag/binary>>` preamble, handed to the
  acceptor process which then owns the stream. Independent QUIC flow control
  per stream; inbound streams awaiting a preamble are capped (64) to bound a
  hostile peer. For bulk byte transfer where message passing is the wrong
  shape. Beta.

### Observability
- `barrel_p2p_metrics`: counters and histograms emitted through the `instrument`
  library at the HyParView, dist-auth, Plumtree, GC, router, service-proxy,
  streams, and migrate seams. Cached in `persistent_term`; emit sites stay off
  the hot path.
- `barrel_p2p_path_stats`: `summary/1`, `srtt/1`, `connection/1` over upstream
  `quic:get_path_stats/1`, resolving a peer node to its QUIC connection pid.

### Tooling
- `priv/bin/barrel_p2p_call.sh`: an `erl_call`-style one-shot RPC helper that
  boots a hidden probe with a full Ed25519 identity and runs `rpc:call` against
  a live node.
- `priv/bin/barrel_p2p_gen_cert.sh`: a self-signed cert generator for the QUIC
  dist channel (`--out-dir`, `--cn`, `--days`, `--key-bits`, `--force`;
  idempotent).

### Tests and CI
- Property-based tests (PropEr) for the OR-Map CRDT laws, HLC monotonicity and
  binary round-trip, dist-protocol encode/decode plus fuzz survival, and the
  stream demuxer under random fragmentation.
- EUnit and Common Test suites covering membership, registry (incl. via
  callbacks and the global bridge), Plumtree, dist auth, two/three-node
  cluster mechanics, the `-proto_dist barrel_p2p` boot path, maps, reminders,
  leader election, sharded placement, and end-to-end convergence and
  partition-heal scenarios. A gated soak suite (`BARREL_P2P_CT_SOAK=1`) and a
  bench harness (`bench/run.sh`) round these out.
- GitHub Actions matrix on OTP 27 and 28: compile, xref, dialyzer, EUnit,
  Common Test, lint (elvis), formatting (erlfmt), and a bench gate.
  Dialyzer- and xref-clean.

### Documentation
- A documentation tree under `docs/` (overview, concepts, tutorials including
  a from-scratch quickstart, how-to guides including key management and
  production, and reference including the configuration list, the replicated
  substrate, and a Partisan comparison), published via `ex_doc`. Runnable
  examples under `examples/`.
- LICENSE (Apache-2.0) and SECURITY.md.

[0.1.0]: https://github.com/barrel-platform/barrel_p2p/releases/tag/v0.1.0
