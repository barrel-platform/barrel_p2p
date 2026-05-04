# Testing

Mycelium ships two layers of tests:

- **Local** — unit and property suites that run inside a single
  BEAM instance. No docker, no network setup.
- **Docker e2e** — multi-container clusters that exercise the
  full distribution carrier (`-proto_dist quic`) and Ed25519
  authentication under a realistic network topology.

## Quick reference

| Command | Scope |
| --- | --- |
| `rebar3 ct` | All non-docker CT suites |
| `rebar3 eunit` | Pure unit tests |
| `rebar3 check` | `xref` + `dialyzer` + `eunit` + `ct` |
| `rebar3 ct --suite=test/mycelium_dist_basic_SUITE` | Two-node cluster mechanics (no docker) |
| `rebar3 ct --suite=test/mycelium_dist_auth_basic_SUITE` | Three-node Ed25519 key/trust API (no docker) |
| `./docker/scripts/run_auth_tests.sh` | Ed25519 strict + TOFU e2e |

The two `*_basic_SUITE` entries spawn slave nodes via `ct_slave` on
the local host. They cover cluster mechanics, registry sync, service
discovery, HyParView shuffle, and the key/trust API in seconds. The
docker suite is authoritative for the full `-proto_dist quic` carrier
behaviour (Ed25519 callback, EPMD registration, cluster join).

## Local tests

Prerequisite: Erlang/OTP 28+, rebar3.

```bash
rebar3 ct
```

A green run reports `Skipped 17 (17, 0) tests. Passed 177 tests.`
The 17 skipped cases come from the docker-only `mycelium_docker_auth_SUITE`;
they print `Docker-only suite. Run via ./docker/scripts/run_auth_tests.sh`
and exit cleanly.

To run a single suite:

```bash
rebar3 ct --suite=test/mycelium_dist_auth_SUITE
rebar3 ct --suite=test/mycelium_dist_basic_SUITE
```

Static checks:

```bash
rebar3 xref       # 0 warnings
rebar3 dialyzer
```

`rebar3 check` chains `xref + dialyzer + eunit + ct` in one go.

## Interactive testing with `rebar3 shell`

Quick way to poke at a running node by hand. Two-node setup
covers most cases.

### Single node

```bash
# Generate the QUIC TLS cert once before first boot.
mkdir -p data/quic
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout data/quic/node.key -out data/quic/node.crt \
    -subj '/CN=mycelium'

ERL_AFLAGS="-proto_dist quic" \
rebar3 shell --sname m1 --setcookie mycelium
```

Without `ERL_AFLAGS="-proto_dist quic"` the node boots on the default
TCP carrier. After boot:

```erlang
%% mycelium starts automatically with the application
1> mycelium:active_view().
[]
2> mycelium:register_service(my_service, #{version => "1.0"}).
ok
3> mycelium:lookup(my_service).
{ok,[{my_service,m1@host,<0.142.0>,#{version => "1.0"}}]}
4> q().
```

### Two-node cluster

In one terminal:

```bash
ERL_AFLAGS="-proto_dist quic" \
rebar3 shell --sname m1 --setcookie mycelium
```

In another terminal:

```bash
ERL_AFLAGS="-proto_dist quic" \
rebar3 shell --sname m2 --setcookie mycelium
```

On `m2`, join the cluster:

```erlang
1> mycelium:join('m1@yourhost').
ok
2> mycelium:active_view().
[m1@yourhost]
3> rpc:call('m1@yourhost', mycelium, active_view, []).
[m2@yourhost]
```

Replace `yourhost` with the short hostname `inet:gethostname/0`
returns. `--sname m1` resolves to `m1@<short-hostname>` on
both shells, and they need to share that.

### Useful inspection

```erlang
%% Cluster + transport
mycelium:active_view().
mycelium:passive_view().
nodes().                            %% all dist-connected peers
sys:get_state(mycelium_hyparview).  %% raw HyParView state

%% quic_dist carrier
erl_epmd:names().                   %% who is registered locally

%% Trust + auth state (only when auth_enabled=true)
mycelium_dist_keys:list_trusted().
mycelium_dist_keys:get_trust_mode().
{ok, MyPub} = mycelium_dist_auth:get_public_key().

%% GUI (visualises supervision tree, processes, ETS tables)
observer:start().
```

### Auth/encryption opt-in

`auth_enabled` defaults to `true` in `config/sys.config`. To run
without auth (faster local poking):

```bash
ERL_AFLAGS="-proto_dist quic -mycelium auth_enabled false" \
rebar3 shell --sname m1 --setcookie mycelium
```

Each node generates its keypair on first boot (under
`data/keys/node.{key,pub}` relative to the working dir) and
records peer fingerprints under `data/keys/trusted/`.

### Tear-down

`q()` in the shell, or `Ctrl-G` then `q` if you want to leave
the BEAM running. `mycelium:leave()` issues a graceful HyParView
disconnect first (useful when you want the peer to clean up its
active view immediately rather than wait for a tick to time out).

## Docker e2e tests

Prerequisites:
- docker and `docker compose` v2

The script brings up a compose stack, runs a CT suite inside the
`test_runner` container, and tears the stack down on exit. CT logs
land under `test_results/`.

```bash
./docker/scripts/run_auth_tests.sh
```

Common flags:

- `--no-build` — reuse the existing image instead of rebuilding.
- `--cleanup` — tear down containers, networks, and volumes from
  a previous run, then exit.

### What the suite covers

**`run_auth_tests.sh` → `mycelium_docker_auth_SUITE`** — three
nodes start with `auth_enabled=true, auth_trust_mode=tofu`. The
suite verifies that the Ed25519 challenge-response runs through
the upstream `quic_dist_auth` callback, that fingerprints are
persisted to `/app/data/keys/trusted/`, and that re-connects
after restart still trust the same peer. The strict-mode profile
(`docker compose --profile strict`) adds an `untrusted_node`
that the cluster rejects.

The `cookie_only_nodes` whitelist short-circuits the Ed25519
handshake for whitelisted probes (the test_runner) and lets the
OTP-level cookie challenge cover the rest. Cluster-internal
connections still run the full Ed25519 challenge-response.

### Reading the results

After the script finishes, the CT log lands in `test_results/`.
Open `test_results/index.html` (or the per-suite `*.html` next to
it) for the case-by-case report. The script's own exit code is `0`
for green, non-zero on any failure.

To clean up between runs:

```bash
./docker/scripts/run_auth_tests.sh --cleanup
```

## Recovery

`rebar3 ct` reports `'<some>_SUITE cannot be compiled or
loaded'` for suites you didn't touch: likely stale `.erl`
files left in `_build/test/lib/mycelium/test/` from a different
branch. Wipe the test profile and try again:

```bash
rebar3 clean -a
rm -rf _build/test
rebar3 ct
```

All deps are public; the docker build needs no github auth.
