# Hello, cluster

This is the smallest end-to-end exercise: two nodes, one
registered service, one cross-node message. If you have read
[Getting started](../overview/getting-started.md), you have
already done most of this; the goal here is to put it in one
self-contained tutorial.

## Prerequisites

- Erlang/OTP 27 or later.
- `rebar3`.
- An empty project (or any project where you can add a
  dependency).

## Step 1: add the dependency

In your `rebar.config`:

```erlang
{deps, [
    {barrel_p2p, "0.1.0"}
]}.

{ex_doc, [
    {extras, [<<"README.md">>]}
]}.
```

Fetch and compile:

```bash
rebar3 get-deps
rebar3 compile
```

## Step 2: minimal sys.config

`config/sys.config`:

```erlang
[
    {barrel_p2p, [
        {active_size, 5},
        {passive_size, 30},
        {listen_port, 9100},
        {auth_enabled, true},
        {auth_trust_mode, tofu}
    ]}
].
```

## Step 3: start two nodes

In one terminal:

```bash
ERL_AFLAGS="-proto_dist barrel_p2p -epmd_module barrel_p2p_epmd -start_epmd false" \
rebar3 shell --config config/sys.config --sname node1
```

In another:

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
```

Replace `yourhost` with the short hostname from
`inet:gethostname/0`. Both shells need to resolve the same
hostname.

## Step 4: register a service

On `node1`:

```erlang
1> Pid = spawn(fun() -> timer:sleep(infinity) end).
<0.123.0>
2> barrel_p2p:register_service(my_worker, Pid, #{role => worker}).
ok
```

On `node2`, after a moment:

```erlang
3> {ok, _Node, FoundPid} = barrel_p2p:whereis_service(my_worker).
{ok, 'node1@yourhost', <0.123.0>}
4> FoundPid ! hello.
hello
```

The `whereis_service/1` call returns `{ok, Node, Pid}` for a
remote service. The send-bang uses standard Erlang distribution
on top of the barrel_p2p dist channel.

## Step 5: subscribe to events

Still on `node2`:

```erlang
5> barrel_p2p:subscribe_services().
ok
```

Now have `node1` register and unregister a service:

```erlang
%% On node1
3> barrel_p2p:register_service(another, #{}).
4> barrel_p2p:unregister_service(another).
```

On `node2`, the listening process receives:

```erlang
{barrel_p2p_service_event, {service_registered, another, 'node1@yourhost'}}
{barrel_p2p_service_event, {service_unregistered, another, 'node1@yourhost'}}
```

The subscription is per-pid. Use it to invalidate caches or to
trigger application-level reactions to cluster changes.

## What this tutorial covered

- Booting a node with `-proto_dist barrel_p2p`.
- Joining a peer with `barrel_p2p:join/1`.
- Registering a service with metadata.
- Discovering the service from another node.
- Subscribing to service events.

## Next

- [Distributed chat](distributed-chat.md) — the same primitives
  applied to a small chat application.
- [Service registry concept](../concepts/service-registry.md) —
  how registration and discovery work under the hood.
- [Cluster membership concept](../concepts/cluster-membership.md)
  — how HyParView keeps the membership bounded.
