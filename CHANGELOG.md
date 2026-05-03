# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `mycelium:migrate_peer/1,2` — RFC 9000 §9 path migration on the
  per-peer QUIC dist channel; rebinds to a new local 4-tuple without
  rekey or HyParView churn.
- `mycelium_path_stats:connection/1` — public helper that resolves a
  node atom to the underlying QUIC connection pid (used by both
  `summary/1` and `migrate_peer/1`).
- `mycelium_dist_keys:fingerprint/1` — SHA-256 fingerprint of an
  Ed25519 public key for diagnostics (logs, key-mismatch reports).
- `docs/migration.md` — connection-migration API and a custom-trigger
  watchdog recipe.
- `docs/external-relay.md` — guide for wiring an out-of-tree
  tunnel/relay adapter via `quic_dist:set_connect_options/2`.
- `mycelium_streams` — tagged user-stream multiplex (single acceptor
  per node); reserved tag `<<"mycelium:circuit">>`.
- Multi-hop circuits v2 (`mycelium_circuit*`): byte-perfect migration
  across hop failure (48-bit frame seqs, cumulative ACKs, symmetric
  RESUME exchange).
- RTT-aware path selection: `mycelium_router:find_path/1,2` and
  `mycelium_path_stats:srtt/1`/`summary/1` over upstream
  `quic:get_path_stats/1`.
- GitHub Actions CI: matrix on OTP 27/28 plus a gated multi-node
  CT job; `compile`, `xref`, `dialyzer`, `eunit`, and `ct` all
  required.
- Eunit suites: `mycelium_circuit_proto_tests`,
  `mycelium_circuit_link_tests`, `mycelium_streams_tests`,
  `mycelium_path_stats_tests`, `mycelium_router_path_tests`,
  `mycelium_dist_keys_tests`, `mycelium_migrate_peer_tests`.
- CT suite: `mycelium_circuit_multinode_SUITE` (4-node diamond
  topology via upstream `quic_call.sh`; gated on
  `MYCELIUM_CT_QUIC_MULTINODE=1`).

### Changed
- Distribution carrier moved from a vendored `mycelium_dist` to
  upstream `quic_dist`. Mycelium plugs in via `auth_callback`
  (`mycelium_dist_auth_callback`), `discovery_module`
  (`mycelium_quic_discovery`), and `register_with_epmd`.
- `mycelium_circuit:open/1` now auto-routes via
  `mycelium_router:find_path/1`; `open/2` accepts an explicit path
  or an options map (`#{path => P, repath => false, max_hops => N}`).
- `docs/internals.md`, `docs/circuits.md`, `docs/getting-started.md`,
  `README.md` rewritten/refreshed for the v2 architecture and the
  node-keyed `mycelium_dist_keys` API.
- `docs/getting-started.md` troubleshooting snippets fixed (used to
  call a non-existent `fingerprint/1` and the wrong arity for
  `lookup_key/delete_key/store_key`).

### Removed
- All NAT traversal, UDP hole-punching, and firewall-bypass code:
  `mycelium_circuit_*` legacy transports, `mycelium_hole_punch`,
  `mycelium_nat`, `mycelium_nat_cache`, and their CT/docker suites.
- Vendored `mycelium_dist` module set (replaced by upstream
  `quic_dist`).
- Docker-driven integration suites; the local CT suites cover the
  same surface and the multi-node SUITE handles end-to-end.

### Fixed
- Stream handoff in `mycelium_streams` and `mycelium_circuit_relay`:
  `controlling_process/2` now runs before draining queued events,
  so forwarded `{quic_dist_stream, _, {data, _}}` messages don't
  bounce back as `{error, not_owner}`.
- Dialyzer config now pulls `hlc`/`quic`/`public_key`/`crypto`/
  `asn1`/`ssl`/`kernel`/`stdlib` PLTs explicitly; full project is
  warning-free.
- CI: `epmd -daemon` started before CT (basic SUITE needs it); the
  `whitelist_tests` group is `[sequence]` (was `[parallel]`, raced
  on shared app env).
