# Observability

A barrel_p2p cluster has three categories of telemetry you will want
in production: membership transitions, authentication outcomes,
and dist-layer events (broadcast, GC, migration). All of them go
through one module, `barrel_p2p_metrics`, which in turn emits to the
[`instrument`](https://github.com/benoitc/instrument) library.

The principle: every emit site is wrapped in a `try`/`catch`. A
misconfigured exporter cannot crash protocol code. If `instrument`
is not running, the emit becomes a no-op.

This document is the catalogue, organised by subsystem, plus a
short guide on wiring an exporter.

## Conventions

- Instrument names are dot-namespaced under
  `barrel_p2p.<subsystem>.<event>`.
- Attribute keys are atoms: `peer`, `outcome`, `reason`, `role`,
  `from`, `target`.
- Counter values are integers; histogram values are milliseconds.
- The `instrument` application must be started; otherwise emits
  silently no-op.

## Membership (HyParView)

| Name                              | Kind    | Attributes              | Fires when                                   |
|-----------------------------------|---------|-------------------------|----------------------------------------------|
| `barrel_p2p.hyparview.peer_up`      | counter | `peer`                  | A node enters the local active view          |
| `barrel_p2p.hyparview.peer_down`    | counter | `peer`, `reason`        | A node leaves the active view                |
| `barrel_p2p.hyparview.joined`       | counter | -                       | The local node joined the cluster            |
| `barrel_p2p.hyparview.left`         | counter | -                       | The local node left the cluster              |
| `barrel_p2p.hyparview.shuffle`      | counter | `target`                | The local node initiated a shuffle           |
| `barrel_p2p.hyparview.pending_timeout` | counter | `peer`               | A pending JOIN/CONNECT/NEIGHBOR backstop fired |

`reason` is normalised: an atom stays as-is, a `{tag, _}` tuple is
reduced to its tag, anything else becomes `other`.

The `pending_timeout` counter is a backstop. A non-zero rate means
some of your peers are responding to JOIN but never producing a
`peer_connected` or `peer_failed` callback; this usually points at
a network drop in one direction. The cluster recovers, but it is
worth investigating.

## Authentication

| Name                              | Kind      | Attributes              | Records                                       |
|-----------------------------------|-----------|-------------------------|-----------------------------------------------|
| `barrel_p2p.dist.auth.attempts`     | counter   | `role`, `outcome`       | One per handshake attempt                     |
| `barrel_p2p.dist.auth.duration_ms`  | histogram | `role`, `outcome`       | Handshake wall time, milliseconds             |

`role` is `outgoing` (we dialed) or `incoming` (we accepted).
`outcome` is `ok` or `fail`. A handshake that crashes counts as
`fail`; the metric is recorded before the exception is re-raised,
so you never lose an attempt.

A non-trivial fail rate is the signal worth alerting on. A pinned
peer reconnecting with a new key, a wrong cookie, a clock skew
beyond the configured window: all of these surface as `fail`.

## Plumtree gossip

| Name                              | Kind    | Attributes | Fires when                                  |
|-----------------------------------|---------|------------|--------------------------------------------|
| `barrel_p2p.plumtree.gossip.sent`   | counter | -          | Each GOSSIP frame placed on the wire        |
| `barrel_p2p.plumtree.gossip.received` | counter | `from`   | A GOSSIP frame arrives                      |
| `barrel_p2p.plumtree.ihave.sent`    | counter | -          | Each IHAVE frame placed on the wire         |
| `barrel_p2p.plumtree.graft.sent`    | counter | `peer`     | A GRAFT request is sent                     |
| `barrel_p2p.plumtree.prune.sent`    | counter | `peer`     | A PRUNE notification is sent                |

`sent` counters add `length(Peers)` per fanout, so the totals
match the number of frames placed on the wire, not the number of
broadcasts.

A reasonable health check: the ratio of `graft.sent` to
`gossip.received` should be small. A high graft rate means lots
of self-healing, which is usually a symptom of churn in the
active view.

## Idle dist-channel GC

| Name                       | Kind    | Attributes | Fires when                                |
|----------------------------|---------|------------|-------------------------------------------|
| `barrel_p2p.dist_gc.reap`    | counter | `peer`     | The reaper closes an idle dist channel    |

A non-zero rate is normal. It means `Pid ! Msg` opened ad-hoc dist
channels that no one used afterwards. A sustained burst suggests
the sweep period or `min_age` tuning is too aggressive for your
workload, or that your application closes dist channels too often.

## Connection migration

| Name                       | Kind    | Attributes              | Fires when                                |
|----------------------------|---------|-------------------------|-------------------------------------------|
| `barrel_p2p.dist.migrate`    | counter | `peer`, `outcome`       | A call to `barrel_p2p:migrate_peer/1,2`     |

`outcome` is `ok` when path validation succeeded, otherwise
`fail`. If you wrote a custom trigger (see
[migration.md](migrate-connections.md)), the `peer` attribute tells you
which peer the trigger acted on.

## Router and service proxy

| Name                                       | Kind    | Attributes | Fires when                              |
|--------------------------------------------|---------|------------|-----------------------------------------|
| `barrel_p2p.router.request_dropped`          | counter | -          | A route request was refused (cap reached)|
| `barrel_p2p.service_proxy.cast_dropped`      | counter | -          | An overlay cast was refused (cap reached)|

These are *operator signals*. A non-zero rate means the router or
a proxy is hitting its in-flight cap. If sustained, raise
`router_max_in_flight` or `proxy_cast_max_in_flight` in
`sys.config`.

## Streams demultiplexer

| Name                                       | Kind    | Attributes | Fires when                                |
|--------------------------------------------|---------|------------|------------------------------------------|
| `barrel_p2p.streams.preamble_dropped`        | counter | -          | An inbound stream was reset for not completing the tag preamble |

A non-zero rate suggests a buggy peer is opening streams without
sending the tag preamble. In production this should be zero.

## Wiring an exporter

`instrument` does not ship a standalone HTTP server. It gives you
the building blocks; you wire them into whatever HTTP layer your
release already uses.

### Prometheus

`instrument_prometheus` is a *formatter*, not a server. Two
functions matter:

- `instrument_prometheus:format/0` returns the metrics body as a
  binary (Prometheus text exposition format).
- `instrument_prometheus:content_type/0` returns the matching
  `text/plain; version=0.0.4; charset=utf-8` header value.

A minimal cowboy handler:

```erlang
-module(my_metrics_handler).
-export([init/2]).

init(Req0, State) ->
    Body = instrument_prometheus:format(),
    Headers = #{<<"content-type">> => instrument_prometheus:content_type()},
    Req = cowboy_req:reply(200, Headers, Body, Req0),
    {ok, Req, State}.
```

Wire it in your router and point your Prometheus scraper at the
resulting endpoint.

Barrel P2P emits as soon as its supervision tree is up. Make sure
`instrument` is in your release applications list (it is pulled in
as a transitive dependency of barrel_p2p, so you usually do not have
to add it explicitly).

### OTLP

OTLP export is configured through the `instrument` application env
or through the standard `OTEL_*` environment variables. The
canonical setup lives in the upstream
[instrument README](https://github.com/benoitc/instrument);
barrel_p2p does not add or replace any of it.

A typical sys.config entry:

```erlang
{instrument, [
    {service_name, <<"my_barrel_p2p_node">>}
]}.
```

Combined with `OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318`
in the node's environment, this is enough for the metrics to flow.

## What to alert on

A short list of metrics that tend to matter in production:

- **`barrel_p2p.dist.auth.attempts{outcome=fail}` rate.**
  Sustained failures are either a misconfiguration (wrong
  cookie, wrong proto_dist), a clock issue, a rotation in
  progress, or an active attack. Either way they warrant a
  human's attention.
- **`barrel_p2p.hyparview.peer_down{reason=nodedown}` spikes.**
  A burst of node-downs usually means a network event. The
  cluster recovers, but the spike is the trigger for
  investigation.
- **`barrel_p2p.dist_gc.reap` rate vs steady-state baseline.**
  A sudden change either way is worth looking at: a high rate
  suggests an application opening too many ad-hoc dist
  channels; a low rate after a baseline of activity may mean
  channels are not being released.
- **`barrel_p2p.dist.auth.duration_ms` p95.** A creeping p95 is an
  early signal that the cluster is loaded or that the
  authentication code path is contending on file I/O (the
  keypair is read from disk per attempt).
