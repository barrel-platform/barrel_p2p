# Schedule durable jobs

You want to run something at a future time, somewhere in the cluster,
and have it survive the node that scheduled it. A cron-like "run the
nightly rollup at 02:00", a "retry this in 5 minutes", a "expire this
session at midnight". `erlang:send_after/3` dies with its node;
`mycelium:remind/3` does not.

## Schedule a one-shot job

Pick a stable `Key`, an absolute fire time, and a payload. Subscribe so
your process receives the fire:

```erlang
-behaviour(gen_server).

init(_) ->
    ok = mycelium:subscribe_reminders(),
    {ok, #{}}.

schedule_rollup(Date) ->
    Key     = {nightly_rollup, Date},
    FireAt  = at_0200(Date),                 %% ms, system_time scale
    Payload = #{date => Date},
    mycelium:remind(Key, FireAt, Payload).

handle_info({mycelium_reminder, {nightly_rollup, Date}, _Payload, Fence}, S) ->
    {noreply, run_rollup_once(Date, Fence, S)}.
```

The reminder fires on whichever node owns `Key` at 02:00, and is
delivered to that node's subscribers. The work runs there. If the node
that called `schedule_rollup/1` is gone by then, a survivor that took
over the key fires it instead.

## Subscribe everywhere the handler may run

You do not know in advance which node will own the key at fire time, so
subscribe on every node that can do the work. Only the owner delivers,
so exactly one node's subscribers see each fire in steady state. The
simplest shape is a registered worker started on every node, each
subscribing in `init/1`.

## Fire after a delay

When you think in "from now" rather than absolute time:

```erlang
%% Retry in 5 minutes.
mycelium:remind_after({retry, JobId}, 5 * 60 * 1000, JobSpec).
```

`remind_after/3` converts the delay to an absolute target immediately,
so every node agrees on the fire time even though the call happened on
one of them.

## Write an idempotent handler

The guarantee is exactly-once in steady state, best-effort under churn
or a crash at the fire instant (see
[durable reminders](../concepts/durable-reminders.md#what-it-guarantees)).
Treat the delivery as at-least-once and dedup on `Fence`, which is a
stable, comparable id for that exact reminder version:

```erlang
run_rollup_once(Date, Fence, S) ->
    case mark_done(Date, Fence) of    %% atomic check-and-set in your store
        already_done -> S;
        ok           -> do_rollup(Date), S
    end.
```

If the job is naturally idempotent (an upsert, a "set state to expired"),
you can skip the dedup and just run it.

## Reschedule and cancel

Re-setting the same `Key` replaces the reminder with a fresh version and
invalidates the old timer, so reschedule by calling `remind/3` again:

```erlang
mycelium:remind(Key, NewFireAt, Payload).   %% replaces
mycelium:cancel_reminder(Key).              %% cancels cluster-wide
```

## Recurring jobs

Reminders are one-shot. For a recurring job, re-arm the next occurrence
from inside the handler:

```erlang
handle_info({mycelium_reminder, {nightly_rollup, Date}, P, Fence}, S) ->
    S1 = run_rollup_once(Date, Fence, S),
    Next = next_day(Date),
    ok = mycelium:remind({nightly_rollup, Next}, at_0200(Next), P),
    {noreply, S1}.
```

Because the handler runs on the current owner, the chain keeps going
across node deaths: each fire arms the next on whoever owns the key then.

## Mind the clock

Fire time is wall-clock, and nodes do not share a clock. A reminder can
fire a little early or late by the cluster's skew bound. It is right for
"around 02:00", not for hard real-time deadlines. Keep fire times
comfortably larger than the membership lease (`member_ttl_ms`) when you
rely on a survivor taking over after a crash, so the new owner is in the
ring well before the reminder is due.

## See also

- [Durable reminders](../concepts/durable-reminders.md) for the model
  and the exact guarantees.
- [Sharded placement](../concepts/sharded-placement.md) for the
  ownership and hand-off mechanics underneath.
