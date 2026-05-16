# Deployment

Practical guidance for running mycelium in production. Pair with
[`getting-started.md`](getting-started.md) for the initial bring-up.

## Sizing

HyParView keeps a bounded **active view** of size `active_size` (default
5) and a **passive view** of size `passive_size` (default 30). The
active view is what gossip traverses; passive members are warm spares.

`active_size` need not grow with the cluster: HyParView is designed so
each node keeps an O(log n) active view and the gossip tree (Plumtree)
covers the whole cluster from any starting point. As a rule of thumb:

| Cluster size | Suggested `active_size` | Suggested `passive_size` |
|--------------|-------------------------|--------------------------|
| 3–10         | 3                       | 10                       |
| 10–50        | 5 (default)             | 30 (default)             |
| 50–200       | 6                       | 40                       |
| 200+         | 7                       | 60                       |

`Pid ! Msg` works to any cluster member regardless of active-view
membership; `mycelium_dist_gc` reaps the resulting idle dist channels.

Set per node via sys.config:

```erlang
{mycelium, [
    {active_size, 5},
    {passive_size, 30}
]}
```

## Network surface

| Port purpose                | Default | Protocol | Direction       |
|-----------------------------|---------|----------|-----------------|
| QUIC distribution           | `listen_port` env (or auto-assign) | UDP | Bidirectional, peer-to-peer |
| Prometheus scrape (optional)| 9568    | TCP      | Inbound from your scraper |

No EPMD. No separate TCP control channel. Open one UDP port per node;
the QUIC handshake handles encryption, multiplexing, and connection
migration.

## TLS material and secrets

| Asset                                       | Location                              | Sensitivity                |
|---------------------------------------------|---------------------------------------|----------------------------|
| QUIC node certificate                       | `quic_cert_dir/node.crt` (default `data/quic/`) | Public; per-node           |
| QUIC node private key                       | `quic_cert_dir/node.key`              | **Private** — `chmod 0600` |
| Ed25519 identity public key                 | `key_dir/pub.key`                     | Public; advertised in handshake |
| Ed25519 identity private key                | `key_dir/priv.key`                    | **Private** — `chmod 0600` |
| Trusted peer keys (TOFU / pinned)           | `key_dir/trusted/<node>.pub`          | Public; reviewable         |
| Erlang dist cookie                          | `mycelium.dist_cookie` env, default `mycelium` | **Private** — pre-shared secret |

Recommended file mode for the directories: `0700` owner-only.

Both directories can be regenerated on a fresh boot; lose the QUIC key
and peers will reject the new cert until you re-pin (or run in `tofu`
mode). Lose the Ed25519 private key and the node loses its identity
across reconnects.

## Configuration knobs

Set under `{mycelium, [...]}` in sys.config:

| Key                            | Default       | Purpose                                                  |
|--------------------------------|---------------|----------------------------------------------------------|
| `listen_port`                  | `0` (random)  | UDP port for QUIC dist                                   |
| `active_size`                  | `5`           | HyParView active-view bound                              |
| `passive_size`                 | `30`          | HyParView passive-view bound                             |
| `shuffle_period`               | `10000`       | ms between shuffle rounds                                |
| `auth_enabled`                 | `false`       | Turn on Ed25519 challenge-response                       |
| `auth_trust_mode`              | `tofu`        | `tofu` accepts unknown keys on first contact; `strict` does not |
| `auth_handshake_timeout`       | `10000`       | ms before an in-progress auth gives up                   |
| `cookie_only_nodes`            | `[]`          | Whitelist of patterns exempt from Ed25519 (test probes)  |
| `dist_cookie`                  | `mycelium`    | Erlang cookie applied at app start                       |
| `dist_gc_sweep_period_ms`      | `60000`       | Idle GC sweep cadence                                    |
| `dist_gc_min_age_ms`           | `300000`      | Minimum channel age before GC may reap                   |
| `discovery_backends`           | `[]`          | List of `{Module, Args}` for the discovery chain         |

The dist GC has no enable/disable flag: it is a load-bearing part of
the decoupled design. See [`internals.md`](internals.md).

## Log ingestion

Mycelium logs to standard `logger`. Important callsites are listed in
[`troubleshooting.md`](troubleshooting.md). For ingestion, no special
handler is needed; any structured-logger formatter that emits JSON or
logfmt will surface the messages.

Levels used:

- `error` — operational failure (cert generation, listener bind).
- `warning` — recoverable anomaly worth a human glance (key mismatch,
  discovery lookup miss).
- `info` — lifecycle (app start/stop).
- `debug` — protocol-level traces; off in production by default.

## Graceful shutdown

The expected order for stopping a node cleanly:

1. `mycelium:leave/0` — sends HyParView `disconnect` to every active
   peer so they move you to passive view immediately instead of
   waiting for a `nodedown` failure.
2. `application:stop(mycelium)` — tears down the supervision tree.
3. `init:stop/0` — terminates the VM.

The dist GC will then reap any leftover channels on the surviving
peers within `dist_gc_min_age_ms`.

Skipping step 1 is safe but causes a brief failure-shaped churn event
on every peer that had you in active view (`peer_down` with reason
`nodedown`).

## Rotation runbook

`mycelium_rotate` handles both QUIC TLS material and Ed25519 identity
keys. Each call atomically backs the old material up under
`<dir>/backups/<UTC-timestamp>/` and returns the backup path.

### Rotate the Ed25519 identity

Takes effect on the next handshake. No restart needed.

```erlang
{ok, Info} = mycelium_rotate:rotate_identity().
%% Info = #{cert_file := PubPath,
%%          key_file := PrivPath,
%%          backup_dir := BackupPath,
%%          restart_required := false}
```

Caveats:

- Peers running in **strict** trust mode will reject the new identity
  until you re-pin it (manually distribute the new public key, or use
  `mycelium_dist_keys:store_key/2` on each peer).
- Peers running in **tofu** mode will pin the new identity on first
  handshake. Existing trust entries for the old key remain in their
  store and should be cleaned up if you want to disallow rollback.
- The logged warning includes the new SHA-256 fingerprint; record it.

### Rotate the QUIC TLS cert

Requires a node restart for the listener to load the new credentials.

```erlang
{ok, Info} = mycelium_rotate:rotate_cert().
%% Info#{restart_required := true}
```

Recommended sequence per node:

1. Drain by calling `mycelium:leave/0` so peers move you to passive
   view promptly.
2. Call `mycelium_rotate:rotate_cert/0`.
3. `application:stop(mycelium)` followed by `init:stop/0`.
4. Bring the node back up; it loads the new cert at listen time.

Peers will see a transient `peer_down` event and re-establish on next
demand. The Ed25519 identity is independent of the cert and is not
touched.

### Rollback

The backup directory contains the previous `node.crt`/`node.key` (or
`node.pub`/`node.key` for identity). Copy them back over the active
files manually; for cert rotations, restart the node after the swap.

## Capacity planning checklist

- One UDP port per node open in firewalls.
- Discovery directory shared across hosts (file backend) or DNS records
  in place (DNS backend).
- `active_size` and `passive_size` sized to cluster.
- `auth_enabled=true` in any environment that doesn't trust the network.
- `dist_cookie` rotated to a high-entropy secret.
- Cert/key directories on persistent storage backed up.
- `instrument` exporter wired to your monitoring backend.
- Alerts on:
  - sustained `mycelium.dist.auth.attempts{outcome=fail}` rate
  - `mycelium.hyparview.peer_down{reason=nodedown}` spikes
  - `mycelium.dist_gc.reap` rate vs steady-state baseline
