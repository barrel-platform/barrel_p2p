# Deployment

Practical guidance for running a mycelium cluster in production.
Pair this with [getting-started.md](getting-started.md) for the
initial bring-up and [troubleshooting.md](troubleshooting.md) for
the symptoms-and-fixes table.

The structure: sizing, network, secrets, configuration, logging,
shutdown, rotation, and a final checklist.

## Sizing the cluster

The two parameters that matter most are `active_size` and
`passive_size`. The active view is the small bounded set of peers
each node currently exchanges gossip with; the passive view is a
warm-spare cache of additional known peers.

The HyParView protocol does not require the active view to grow
with the cluster. Five peers per node is enough to cover a cluster
of a few thousand. The trade-off is that a slightly larger active
view reduces the number of hops a broadcast takes, at the cost of
more direct connections to maintain.

Suggested starting points:

| Cluster size | `active_size` | `passive_size` |
|--------------|---------------|----------------|
| 3 to 10      | 3             | 10             |
| 10 to 50     | 5 (default)   | 30 (default)   |
| 50 to 200    | 6             | 40             |
| 200+         | 7             | 60             |

`Pid ! Msg` works to any cluster member regardless of active-view
membership. The dist GC reaps the resulting idle dist channels,
so the per-node connection count stays bounded even if your
application talks to many peers ad hoc.

To set these:

```erlang
{mycelium, [
    {active_size, 5},
    {passive_size, 30}
]}.
```

## Network surface

A mycelium node opens one UDP socket. That is the whole
externally-visible network footprint, aside from any metrics
exporter you wire in.

| Port purpose                  | Default                | Protocol | Direction                  |
|-------------------------------|------------------------|----------|----------------------------|
| QUIC distribution             | `listen_port` env or 0 | UDP      | Bidirectional, peer-to-peer |
| Prometheus scrape (optional)  | 9568                   | TCP      | Inbound from your scraper   |

No EPMD. No separate TCP control channel. The QUIC handshake
handles encryption, multiplexing, and connection migration on the
single UDP port.

For production, pin the dist port (do not leave it at `0`):

```erlang
{mycelium, [{listen_port, 9100}]}.
```

Open that port between every pair of cluster nodes in your
firewall.

## Secrets and on-disk material

A node carries four pieces of material on disk. They are listed
here with their default location and sensitivity:

| Asset                                             | Default location                                | Sensitivity                                       |
|---------------------------------------------------|-------------------------------------------------|--------------------------------------------------|
| QUIC node certificate                             | `data/quic/node.crt` (`quic_cert_dir` env)      | Public; per-node                                   |
| QUIC node private key                             | `data/quic/node.key`                            | **Private**; chmod 0600                            |
| Ed25519 identity public key                       | `data/keys/node.pub` (`auth_key_dir` env)       | Public; advertised in handshake                    |
| Ed25519 identity private key                      | `data/keys/node.key`                            | **Private**; chmod 0600                            |
| Trusted peer keys                                 | `data/keys/trusted/<node>.pub`                  | Public; reviewable                                 |
| Erlang dist cookie                                | `mycelium.dist_cookie` env (default `mycelium`) | **Private**; pre-shared secret                     |

Recommended file mode for the parent directories: 0700 (owner
only).

Two recovery properties worth knowing:

- Both private keys can be regenerated on a fresh boot. Lose the
  QUIC private key and your peers will reject the new certificate
  until you re-pin (or run in `tofu` mode). Lose the Ed25519
  private key and the node loses its identity across reconnects.
- The trust store is rebuildable from the peers' public keys; you
  do not need to back it up if you can re-derive it.

Mycelium writes new secrets atomically (write to a temp file with
0600 perms, then rename). A crash during a key rotation will not
leave a permissive transient on disk; the on-disk file is either
the old one or the new one, never something in between.

## Configuration reference

Every key below goes under `{mycelium, [...]}` in `sys.config`.

| Key                              | Default          | Purpose                                                                  |
|----------------------------------|------------------|--------------------------------------------------------------------------|
| `listen_port`                    | `0` (random)     | UDP port for QUIC dist                                                    |
| `active_size`                    | `5`              | HyParView active-view bound                                              |
| `passive_size`                   | `30`             | HyParView passive-view bound                                             |
| `arwl`                           | `6`              | Active random walk length (join propagation)                              |
| `prwl`                           | `3`              | Passive random walk length                                                |
| `shuffle_length`                 | `8`              | Peers exchanged per shuffle round                                         |
| `shuffle_period`                 | `10000` ms       | Time between shuffle rounds                                               |
| `max_fail_count`                 | `5`              | Failures before a peer is demoted to passive                              |
| `base_backoff_ms`                | `1000`           | Initial backoff after a failure                                           |
| `passive_max_age_ms`             | `300000`         | Maximum age before passive entries are dropped                            |
| `auth_enabled`                   | `true`           | Ed25519 challenge-response between peers                                  |
| `auth_trust_mode`                | `tofu`           | `tofu` or `strict`                                                        |
| `auth_handshake_timeout`         | `10000` ms       | Total budget for the Ed25519 handshake                                    |
| `auth_timestamp_window`          | `30000` ms       | Acceptable peer wall-clock skew                                           |
| `cookie_only_nodes`              | `[]`             | Patterns of node atoms exempt from Ed25519                                |
| `dist_cookie`                    | `mycelium`       | Erlang dist cookie applied at app start                                   |
| `dist_gc_sweep_period_ms`        | `60000`          | Idle GC sweep cadence                                                     |
| `dist_gc_min_age_ms`             | `300000`         | Minimum age before GC may reap a channel                                  |
| `pending_timeout_ms`             | `30000`          | Backstop for HyParView pending entries (silent peers)                     |
| `router_max_in_flight`           | `256`            | Cap on concurrent overlay route-request handlers                          |
| `proxy_cast_max_in_flight`       | `32`             | Per-proxy cap on concurrent overlay-cast helpers                          |
| `route_cache_sweep_period_ms`    | `60000`          | Periodic sweep of stale route-cache entries                               |
| `contact_nodes`                  | `[]`             | Bootstrap node atoms tried on application start                           |
| `discovery_backends`             | (default chain)  | List of `{Module, Args}` for the discovery chain                          |

The dist GC has no enable/disable flag: the decoupled-from-active-view
design depends on it (`Pid ! Msg` to any peer opens an ad-hoc
channel; the GC keeps the overall connection count bounded). The
sweep cadence and minimum age are tunable.

## Logging

Mycelium logs to standard `logger`. The levels we use:

- `error` for operational failure (cert generation, listener bind
  failure, keypair load mismatch).
- `warning` for recoverable anomalies worth a human glance (key
  mismatch, discovery lookup miss, pending-entry backstop fire).
- `info` for lifecycle (app start/stop).
- `debug` for protocol-level traces; off in production by default.

No special handler is required. Any structured-logger formatter
that emits JSON or logfmt will surface the messages.

The important log call-sites are listed in
[troubleshooting.md](troubleshooting.md); use it as a grep
reference when investigating an alert.

## Graceful shutdown

The clean shutdown order is three steps:

1. `mycelium:leave/0`. Sends a HyParView `disconnect` to every
   active peer so they move you to passive view immediately
   instead of waiting for a `nodedown` failure.
2. `application:stop(mycelium)`. Tears down the supervision tree
   in reverse order; the dist GC will reap the remaining
   channels from the *other* side over the next sweep window.
3. `init:stop/0`. Terminates the VM.

Skipping step 1 is safe but causes a brief failure-shaped churn
event on every peer that had you in active view (`peer_down` with
reason `nodedown`). For an orchestrator-driven restart, step 1
is worth the few extra milliseconds.

## Rotation runbook

`mycelium_rotate` handles both QUIC TLS material and Ed25519
identity keys. Each call atomically backs the old material up
under `<dir>/backups/<UTC-timestamp>/`.

### Identity rotation (no restart needed)

Takes effect on the next handshake:

```erlang
{ok, Info} = mycelium_rotate:rotate_identity().
%% Info = #{key_file        := PrivPath,
%%          cert_file       := PubPath,
%%          backup_dir      := BackupPath,
%%          restart_required := false}
```

Caveats:

- **Strict peers** will reject the new identity until you have
  provisioned the new public key on each of them.
- **TOFU peers** will pin the new identity on first handshake.
  Their old pin remains in the trust store; clean it up if you
  want to prevent rollback.
- The log line on a successful rotation includes the new
  fingerprint. Record it for audit.

### Certificate rotation (restart required)

QUIC TLS material is loaded at listener start. Rotating requires
a restart:

1. `mycelium:leave/0` so peers move you to passive view promptly.
2. `mycelium_rotate:rotate_cert/0`.
3. `application:stop(mycelium)`; `init:stop/0`.
4. Boot the node back up; the listener picks up the new cert.

Peers see one `peer_down` and re-establish on next demand. The
Ed25519 identity is independent of the cert; it is not touched
by this path.

### Rollback

The backup directory keeps the previous `node.crt` / `node.key`
(cert rotation) or `node.pub` / `node.key` (identity rotation).
Copy them back over the active files. For cert rotations,
restart the node after the swap.

## Capacity planning checklist

A quick checklist before promoting a cluster to production:

- One UDP port pinned and open between every node pair in the
  firewall.
- Discovery configured: shared directory for the file backend, or
  DNS records for the DNS backend, or static topology for the
  static backend.
- `active_size` and `passive_size` sized to the cluster.
- `auth_enabled = true` (the default).
- `dist_cookie` rotated to a high-entropy secret. The default
  cookie `mycelium` is a placeholder.
- Cert and key directories on persistent storage; rotation
  backup directory included in your backup policy.
- `instrument` exporter wired to your monitoring backend.
- Alerts on:
  - `mycelium.dist.auth.attempts{outcome=fail}` sustained rate.
  - `mycelium.hyparview.peer_down{reason=nodedown}` spikes.
  - `mycelium.dist_gc.reap` rate vs steady-state baseline.
  - `mycelium.dist.auth.duration_ms` p95 trending up.
- A documented runbook for cert rotation and identity rotation.
- A documented procedure for adding and removing a node from the
  cluster.

## Containers and orchestrators

Two notes for containerised deployments:

- Mycelium needs persistent storage for `data/quic/` and
  `data/keys/`. On Kubernetes, mount a PersistentVolumeClaim
  per pod. On docker-compose, mount a named volume per service.
  Re-generating these on every restart is technically supported
  (TOFU peers will simply re-pin), but it defeats most of the
  point of Ed25519.
- Discovery: on Kubernetes, use a Service with a DNS name; on
  docker-compose, use a static topology file (see
  `docker/cluster-topology.config` in the project tree); on bare
  metal, share the file-discovery directory between hosts.

The docker-compose stack under `docker/` is the canonical
reference for a small, fully-authenticated cluster. Read its
`docker-compose-auth.yml` and `cluster-topology.config` if you
want to mirror the pattern.
