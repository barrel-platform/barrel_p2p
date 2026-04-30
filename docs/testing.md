# Testing

Mycelium ships two layers of tests:

- **Local** — unit and property suites that run inside a single
  BEAM instance. No docker, no network setup.
- **Docker e2e** — multi-container clusters that exercise the
  full distribution carrier (`-proto_dist mycelium`), Ed25519
  authentication, and circuit relay routing under a realistic
  network topology.

## Quick reference

| Command | Scope |
| --- | --- |
| `rebar3 ct` | All non-docker CT suites |
| `rebar3 eunit` | Pure unit tests |
| `rebar3 check` | `xref` + `dialyzer` + `eunit` + `ct` |
| `rebar3 ct --suite=test/mycelium_circuit_SUITE` | One suite |
| `./docker/scripts/run_tests.sh` | 3-node cluster e2e |
| `./docker/scripts/run_auth_tests.sh` | Ed25519 strict + TOFU e2e |
| `./docker/scripts/run_circuit_tests.sh` | Multi-network circuit relay e2e |

## Local tests

Prerequisite: Erlang/OTP 28+, rebar3.

```bash
rebar3 ct
```

A green run reports `Skipped 57 (57, 0) tests. Passed 247 tests.`
The 57 skipped cases come from the three docker-only suites
(`mycelium_integration_SUITE`, `mycelium_docker_auth_SUITE`,
`mycelium_docker_circuit_SUITE`); they print `Docker-only suite.
Run via ./docker/scripts/<name>.sh` and exit cleanly. They are
only exercised when run through the docker scripts below.

To run a single suite:

```bash
rebar3 ct --suite=test/mycelium_circuit_SUITE
rebar3 ct --suite=test/mycelium_dist_auth_SUITE
rebar3 ct --suite=test/mycelium_circuit_reachability_SUITE
```

Static checks:

```bash
rebar3 xref       # 0 new warnings vs baseline
rebar3 dialyzer   # 151 warnings is the current baseline
```

`rebar3 check` chains `xref + dialyzer + eunit + ct` in one go.

## Docker e2e tests

Prerequisites:
- docker and `docker compose` v2
- a github auth token in `GH_TOKEN`, or the `gh` CLI logged in
  (`gh auth login`). The build pulls a private dependency
  (`erlang_masque`); the run scripts auto-export the token from
  `gh auth token` if `GH_TOKEN` is unset.

The three scripts each bring up a compose stack, run a CT suite
inside the `test_runner` container, and tear the stack down on
exit. CT logs land under `test_results/`.

```bash
./docker/scripts/run_tests.sh           # 3-node cluster
./docker/scripts/run_auth_tests.sh      # Ed25519 auth
./docker/scripts/run_circuit_tests.sh   # multi-network circuit relay
```

Common flags (all three scripts):

- `--no-build` — reuse the existing image instead of rebuilding.
- `--cleanup` — tear down containers, networks, and volumes from
  a previous run, then exit.

`run_tests.sh` also accepts `--5node` to use the 5-node compose
profile.

### What each suite covers

**`run_tests.sh` → `mycelium_integration_SUITE`** — three
mycelium nodes (`node1`, `node2`, `node3`) form a HyParView
cluster on the default compose network. Tests cover basic RPC,
active-view membership, gen_server calls across the cluster,
node leave/rejoin, registry sync, and overlay routing
(`mycelium:whereis_service/1`, service proxies, global
transparency).

**`run_auth_tests.sh` → `mycelium_docker_auth_SUITE`** — three
nodes start with `auth_enabled=true, auth_trust_mode=tofu`. The
suite verifies that the Ed25519 in-handshake exchange runs on
the dedicated auth stream, that fingerprints are persisted to
`/app/data/keys/trusted/`, and that re-connects after restart
still trust the same peer. The strict-mode profile
(`docker compose --profile strict`) adds an `untrusted_node`
that the cluster rejects.

> **Status:** the suite runs end-to-end. The `cookie_only_nodes`
> whitelist short-circuits the Ed25519 handshake for whitelisted
> probes (the test_runner) and lets the OTP-level cookie
> challenge cover the rest. Cluster-internal connections still
> run the full Ed25519 challenge-response.

**`run_circuit_tests.sh` → `mycelium_docker_circuit_SUITE`** —
four nodes across three docker networks:

- `network_a` (172.30.0.0/24): `node1` (initiator)
- `network_b` (172.31.0.0/24): `node4` (destination)
- `network_relay` (172.32.0.0/24): `node2`, `node3` (relays)

`node1` and `node4` cannot reach each other directly, so the
suite exercises multi-hop relay circuits, end-to-end encryption
through the relays, and bidirectional data flow through the
circuit transport over the per-peer `mycelium_dist` QUIC
connection.

> **Status:** the suite runs end-to-end. Same
> `cookie_only_nodes` whitelist mechanism that unblocks the auth
> suite applies here.

### Reading the results

After each script, the per-suite CT log lands in
`test_results/`. Open `test_results/index.html` (or the
per-suite `*.html` next to it) for the case-by-case report.
The script's own exit code is `0` for green, non-zero on any
failure.

To clean up between runs:

```bash
./docker/scripts/run_tests.sh --cleanup
./docker/scripts/run_auth_tests.sh --cleanup
./docker/scripts/run_circuit_tests.sh --cleanup
```

## Recovery

`rebar3 ct` reports `'<some>_SUITE cannot be compiled or
loaded'` for suites you didn't touch — likely stale `.erl`
files left in `_build/test/lib/mycelium/test/` from a different
branch. Wipe the test profile and try again:

```bash
rebar3 clean -a
rm -rf _build/test
rebar3 ct
```

Docker `rebar3 get-deps` fails with `Failed to fetch and copy
dep` for a git ref — the upstream branch was force-pushed and
the locked SHA no longer exists. Refresh the lock and rebuild:

```bash
rebar3 unlock <name>
rebar3 get-deps
./docker/scripts/run_tests.sh
```

Docker build prompts for github auth or fails on a private dep
(`erlang_masque` is private). The run scripts read `gh auth
token` automatically when `GH_TOKEN` is unset; if you don't use
the `gh` CLI, export it manually:

```bash
GH_TOKEN=ghp_xxx ./docker/scripts/run_tests.sh
```

The token is passed as a build arg, used only to rewrite
`https://github.com/` URLs during `rebar3 get-deps`, and is
stripped from the layer before the runtime image is built.
