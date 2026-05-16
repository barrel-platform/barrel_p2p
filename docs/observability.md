# Observability

Mycelium emits OpenTelemetry-style metrics through the
[`instrument`](https://github.com/benoitc/instrument) library. The
catalog below lists every instrument the runtime exposes, what each one
measures, and the attributes attached. All emit sites are routed
through `mycelium_metrics` so callsites stay terse and the catalog stays
in one place.

To stream events to a backend, set up an `instrument` exporter
(Prometheus, OTLP, or `instrument_live` for live WebSocket/SSE).

## Conventions

- Instrument names are dot-namespaced under `mycelium.<subsystem>.<event>`.
- Attribute keys are bare atoms (`peer`, `outcome`, `reason`).
- All emit paths are wrapped in `try/catch`: a misconfigured exporter
  never crashes the protocol.
- The `instrument` application must be running for metrics to record.
  When it is stopped, emits become no-ops.

## Instruments

### HyParView membership

| Name                              | Kind    | Attributes              | Increments on                                |
|-----------------------------------|---------|-------------------------|----------------------------------------------|
| `mycelium.hyparview.peer_up`      | counter | `peer`                  | A node enters the local active view          |
| `mycelium.hyparview.peer_down`    | counter | `peer`, `reason`        | A node leaves the active view                |
| `mycelium.hyparview.joined`       | counter | -                       | Local node joined a cluster                  |
| `mycelium.hyparview.left`         | counter | -                       | Local node left a cluster                    |
| `mycelium.hyparview.shuffle`      | counter | `target`                | Local node initiates a shuffle round         |

`reason` is normalised from the protocol shape: an atom stays as-is, a
`{tag, _}` tuple is reduced to its tag, anything else becomes `other`.

### Distribution authentication

| Name                              | Kind      | Attributes              | Records                                       |
|-----------------------------------|-----------|-------------------------|-----------------------------------------------|
| `mycelium.dist.auth.attempts`     | counter   | `role`, `outcome`       | One per handshake attempt                     |
| `mycelium.dist.auth.duration_ms`  | histogram | `role`, `outcome`       | Handshake wall time in milliseconds           |

- `role` is `outgoing` (we initiated) or `incoming` (peer initiated).
- `outcome` is `ok` or `fail`. Crashes inside the handshake count as
  `fail` and the exception is then re-raised; the metric records the
  attempt either way.

### Plumtree gossip

| Name                                  | Kind    | Attributes | Increments on                              |
|---------------------------------------|---------|------------|--------------------------------------------|
| `mycelium.plumtree.gossip.sent`       | counter | -          | Each GOSSIP frame sent to an eager peer    |
| `mycelium.plumtree.gossip.received`   | counter | `from`     | A GOSSIP frame is received                 |
| `mycelium.plumtree.ihave.sent`        | counter | -          | Each IHAVE frame sent to a lazy peer       |
| `mycelium.plumtree.graft.sent`        | counter | `peer`     | A GRAFT request is sent                    |
| `mycelium.plumtree.prune.sent`        | counter | `peer`     | A PRUNE notification is sent               |

Sent counters add `length(Peers)` per fanout, so the totals match the
number of frames placed on the wire, not the number of broadcasts.

### Idle dist-channel GC

| Name                              | Kind    | Attributes | Increments on                                |
|-----------------------------------|---------|------------|----------------------------------------------|
| `mycelium.dist_gc.reap`           | counter | `peer`     | A dist channel is reaped by the idle sweeper |

A non-zero rate here is normal: it just means `Pid ! Msg` opened ad-hoc
dist channels that no one used afterwards. A sustained burst suggests
the sweep period or min-age tuning is too aggressive for the workload.

### Connection migration

| Name                              | Kind    | Attributes              | Increments on                                |
|-----------------------------------|---------|-------------------------|----------------------------------------------|
| `mycelium.dist.migrate`           | counter | `peer`, `outcome`       | A call to `mycelium:migrate_peer/1,2`        |

`outcome` is `ok` when path validation succeeded, otherwise `fail`.

## Wiring an exporter

The simplest path is the Prometheus scrape endpoint shipped with
`instrument`:

```erlang
%% In your release config or boot script
{ok, _} = application:ensure_all_started(instrument),
ok = instrument_prometheus:start([{port, 9568}]).
```

Mycelium emits as soon as the supervision tree is up.

For OTLP, configure the OTLP exporter via the `instrument` application
env. See the upstream README for the canonical setup.

For local development, `instrument_live` exposes a WebSocket and SSE
stream on `http://localhost:8080/stream/events` with no extra wiring.
