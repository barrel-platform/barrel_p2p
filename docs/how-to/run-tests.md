# Testing

Barrel P2P ships three layers of tests, in order of increasing
realism:

- **EUnit and CT suites that run inside a single BEAM.** Property
  tests, gen_server fixtures, small two-node CT cases driven by
  `ct_slave` or `peer`. No docker, no external network.
- **Local multi-node CT suites** that spawn slave BEAMs on the
  same host and exercise the full dist handshake, including
  Ed25519 authentication and the `-proto_dist barrel_p2p` boot
  path. Still no docker.
- **Docker e2e suites** that bring up a multi-container cluster
  on a bridged docker network, with the full transport, Ed25519
  authentication, and orchestrated startup ordering.

This document explains what each layer covers, how to run it,
and where to look when something fails.

## Quick reference

| Command                                              | Scope                                                                 |
|------------------------------------------------------|-----------------------------------------------------------------------|
| `rebar3 eunit`                                       | All EUnit tests (pure)                                                |
| `rebar3 ct`                                          | All non-docker CT suites                                              |
| `rebar3 check`                                       | `xref` + `dialyzer` + `eunit` + `ct` (the green-or-not signal)        |
| `rebar3 ct --suite=test/<name>_SUITE`                | One CT suite                                                          |
| `BARREL_P2P_CT_SOAK=1 rebar3 ct --suite=test/barrel_p2p_soak_SUITE` | The gated soak suite                                          |
| `./docker/scripts/run_auth_tests.sh`                 | Docker compose stack + auth integration suite                         |
| `./docker/scripts/run_auth_tests.sh --no-build`      | Same, reusing the existing image                                      |
| `./docker/scripts/run_auth_tests.sh --cleanup`       | Tear down a previous run, do nothing else                             |

A clean `rebar3 check` reports `Passed N tests. Skipped K (K, 0)
tests.` where K accounts for the docker-only suite and the gated
soak suite, both of which print a `tc_user_skip` and exit
cleanly.

## EUnit and property tests

These live under `test/*_tests.erl` (EUnit) and
`test/*_prop_tests.erl` (proper). They are fast and have no
external dependencies.

```bash
rebar3 eunit
```

The interesting ones for understanding the system:

| Module                                         | Covers                                                          |
|------------------------------------------------|-----------------------------------------------------------------|
| `barrel_p2p_ormap_prop_tests`                    | CRDT laws: commutativity, associativity, idempotence            |
| `barrel_p2p_hlc_prop_tests`                      | HLC monotonicity, total ordering, binary round-trip             |
| `barrel_p2p_dist_protocol_prop_tests`            | Auth-protocol decode round-trip and fuzz survival               |
| `barrel_p2p_streams_prop_tests`                  | Tag preamble demux under random fragmentation                   |
| `barrel_p2p_streams_tests`                       | Tagged user-stream demuxer edge cases                            |
| `barrel_p2p_dist_keys_tests`                     | Trust store ops, atomic writes, fingerprint helper              |
| `barrel_p2p_dist_tests`                          | `project_defaults/0` boot-time validation                        |
| `barrel_p2p_file_tests`                          | Secure-write helper (chmod-before-write + rename)               |
| `barrel_p2p_quic_cert_tests`                     | Cert encoding (RFC 5280 validity, CSPRNG serial)                |

To run a single module:

```bash
rebar3 eunit --module=barrel_p2p_ormap_prop_tests
```

## Local CT suites

These live under `test/*_SUITE.erl`. Most are single-node CT
suites that exercise one module's gen_server behaviour. A few are
multi-node:

| Suite                                | What it covers                                                                  |
|--------------------------------------|---------------------------------------------------------------------------------|
| `barrel_p2p_dist_basic_SUITE`          | Two-node cluster mechanics via `ct_slave` (no docker)                           |
| `barrel_p2p_dist_auth_basic_SUITE`     | Three-node Ed25519 key / trust API via `ct_slave`                               |
| `barrel_p2p_dist_auth_SUITE`           | Single-node CT around the auth protocol primitives                              |
| `barrel_p2p_proto_dist_SUITE`          | `-proto_dist barrel_p2p` boot path via the `peer` module                          |
| `barrel_p2p_audit_e2e_SUITE`           | End-to-end coverage for the audit fixes (TOFU re-pin, AUTH_OK gate, etc.)       |
| `barrel_p2p_hyparview_SUITE`           | HyParView state machine, including the pending-entry backstop                   |
| `barrel_p2p_plumtree_SUITE`            | Plumtree broadcast tree, subscriber lifecycle                                   |
| `barrel_p2p_registry_SUITE`            | Service registry, proxies, via-callbacks                                        |
| `barrel_p2p_router_SUITE`              | Service overlay routing, cache sweep, in-flight cap                              |
| `barrel_p2p_service_proxy_SUITE`       | Proxy fan-out cap, relay TTL/visited                                            |
| `barrel_p2p_failure_SUITE`             | Failure scenarios under churn                                                   |
| `barrel_p2p_churn_SUITE`               | Sustained join/leave behaviour                                                  |
| `barrel_p2p_ormap_SUITE`               | CRDT add/remove/merge                                                            |
| `barrel_p2p_hlc_SUITE`                 | HLC integration                                                                  |
| `barrel_p2p_soak_SUITE`                | Gated soak (`BARREL_P2P_CT_SOAK=1`); broadcast burst on 5 nodes                   |

To run one suite:

```bash
rebar3 ct --suite=test/barrel_p2p_dist_basic_SUITE
```

To run a single case:

```bash
rebar3 ct --suite=test/barrel_p2p_proto_dist_SUITE --case=two_node_connect
```

CT logs land in `_build/test/logs/`. The HTML index is
`_build/test/logs/index.html`.

## Soak suite

```bash
BARREL_P2P_CT_SOAK=1 rebar3 ct --suite=test/barrel_p2p_soak_SUITE.erl
```

One active case (`broadcast_burst`): five nodes, 40 plumtree
broadcasts at 50 ms intervals, asserts every subscriber receives
every marker. Useful as a regression check on the gossip layer.

Other scaffolding cases (partition-and-heal,
cross-active-view-bang) live in the suite but are commented out
of `all/0`; they have proven flaky under QUIC dist and we run
them only manually.

## Docker e2e

```bash
./docker/scripts/run_auth_tests.sh
```

What happens:

1. The script builds the multi-stage Docker image
   (`docker/Dockerfile`).
2. `docker compose -f docker/docker-compose-auth.yml up` brings
   up three cluster nodes (`node1`, `node2`, `node3`) with
   `auth_enabled=true` and `auth_trust_mode=tofu`, and a
   `test_runner` container.
3. The test_runner waits for the cluster to be healthy
   (`/tmp/barrel_p2p_ready` marker on each node), then runs
   `barrel_p2p_docker_auth_SUITE`.
4. The script exits with the test_runner's exit code; the stack
   is torn down.

What the suite covers:

- Three-node TOFU bootstrap: each peer pins the others on first
  contact.
- The Ed25519 challenge-response running through the upstream
  `quic_dist_auth` callback.
- Trust persistence across restarts.
- Whitelist (`cookie_only_nodes`) pattern matching.
- Service registration and RPC across the cluster.
- Cluster reformation after a node restart.

Flags:

- `--no-build` reuses the existing image (faster after a code
  change confined to test files).
- `--cleanup` tears down containers, networks, and volumes from
  a previous run.

CT logs from the docker run land in `test_results/` on the host
(via a bind mount).

### Reading the results

`test_results/index.html` is the top-level CT report.
`test_results/all_runs.html` lists every run; click into a
specific one to see the per-case HTML.

The script's own exit code is `0` for green, non-zero on any
failure. CI consumes the exit code; the HTML is for humans.

## Interactive testing

For poking at a running cluster by hand:

```bash
ERL_AFLAGS="-proto_dist barrel_p2p -epmd_module barrel_p2p_epmd -start_epmd false" \
rebar3 shell --config config/sys.config --sname node1
```

In another terminal:

```bash
ERL_AFLAGS="-proto_dist barrel_p2p -epmd_module barrel_p2p_epmd -start_epmd false" \
rebar3 shell --config config/sys.config --sname node2
```

On `node2`:

```erlang
1> barrel_p2p:join('node1@yourhost').
ok
2> barrel_p2p:active_view().
['node1@yourhost']
3> rpc:call('node1@yourhost', barrel_p2p, active_view, []).
['node2@yourhost']
```

`inet:gethostname/0` tells you the short hostname; both shells
need to resolve to the same `yourhost`.

Useful inspection:

```erlang
%% Cluster + transport
barrel_p2p:active_view().
barrel_p2p:passive_view().
nodes().
sys:get_state(barrel_p2p_hyparview).

%% Trust + auth
barrel_p2p_dist_keys:list_trusted().
barrel_p2p_dist_keys:get_trust_mode().
{ok, Pub} = barrel_p2p_dist_auth:get_public_key().
barrel_p2p_dist_keys:fingerprint(Pub).

%% Process view
observer:start().
```

To run without auth (for faster local poking):

```bash
ERL_AFLAGS="-proto_dist barrel_p2p -epmd_module barrel_p2p_epmd -start_epmd false -barrel_p2p auth_enabled false" \
rebar3 shell --sname node1
```

## Recovery

`rebar3 ct` reports `'<some>_SUITE cannot be compiled or loaded'`
for a suite you have not touched: probably stale `.erl` files
left in `_build/test/lib/barrel_p2p/test/` from a different branch.
Wipe the test profile and try again:

```bash
rebar3 clean -a
rm -rf _build/test
rebar3 ct
```

`peer:start` boot-timeout errors during a CT run usually mean
the parent's code path was not propagated to the spawned BEAM.
The convention used by the suites is to pass `-pa` flags built
from `code:get_path/0` explicitly; check the suite's
`start_peer/3` helper if you see this.

## Adding your own test

For a new EUnit module, create `test/<name>_tests.erl` and add
test functions ending in `_test/0` or `_test_/0`. Properties go
in `test/<name>_prop_tests.erl` using the `proper` macro form
shown in the existing files.

For a CT suite, create `test/<name>_SUITE.erl` with the standard
`all/0`, `init_per_suite/1`, etc. Multi-node CT cases should
reuse the `start_peer/3` helper from
`barrel_p2p_proto_dist_SUITE` (which is `-compile([export_all])`
specifically to be reusable across suites).
