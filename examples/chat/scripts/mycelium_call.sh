#!/usr/bin/env bash
#
# mycelium_call.sh — erl_call-style one-shot RPC over a mycelium
# (-proto_dist quic) cluster, with Ed25519 dist authentication.
#
# Boots a hidden probe BEAM, loads mycelium so the auth callback and
# discovery module are available, starts just enough mycelium state
# for the dist handshake (mycelium_dist_keys reads the on-disk
# keypair), then connects to the target and runs rpc:call/5.
#
# Usage:
#   mycelium_call.sh <Node> <Module> <Function> [ArgsTerm]
#
# Env vars (with defaults):
#   COOKIE       dist cookie (required; default 'chat')
#   CERT, KEY    TLS material   (default data/quic/node.{crt,key})
#   KEY_DIR      Ed25519 keys   (default data/keys)
#   STATIC_NODE  "Node Host Port" triple, e.g.
#                "seed@$(hostname -s) 127.0.0.1 9100"
#                (required for the probe to find the target)
#   TIMEOUT      rpc:call timeout ms (default 10000)

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <Node> <Module> <Function> [ArgsTerm]" >&2
    exit 2
fi

NODE="$1"; MOD="$2"; FUN="$3"; ARGS="${4:-[]}"
COOKIE="${COOKIE:-chat}"
CERT="${CERT:-$PWD/data/quic/node.crt}"
KEY="${KEY:-$PWD/data/quic/node.key}"
KEY_DIR="${KEY_DIR:-$PWD/data/keys}"
TIMEOUT="${TIMEOUT:-10000}"
STATIC_NODE="${STATIC_NODE:-${NODE} 127.0.0.1 9100}"

read -r STATIC_NAME STATIC_HOST STATIC_PORT <<< "$STATIC_NODE"

PROBE_NAME="mycelium_call_$$@$(hostname -s)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHAT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$CHAT_ROOT/../.." && pwd)"

EBINS=( "$PROJECT_ROOT/_build/default/lib"/*/ebin )
EBINS+=( "$PROJECT_ROOT/_build/default/checkouts"/*/ebin )

EVAL=$(cat <<ERL
%% Configure dist (auth + discovery) BEFORE starting mycelium pieces.
ok = application:load(mycelium),
ok = application:set_env(mycelium, auth_enabled, true),
ok = application:set_env(mycelium, auth_key_dir, "${KEY_DIR}"),
ok = application:set_env(mycelium, auth_trust_mode, tofu),
ok = application:set_env(quic, dist, [
    {cert_file, <<"${CERT}">>},
    {key_file,  <<"${KEY}">>},
    {discovery_module, mycelium_quic_discovery},
    {auth_callback, {mycelium_dist_auth_callback, authenticate}},
    {auth_handshake_timeout, 10000},
    {nodes, [{'${STATIC_NAME}', {"${STATIC_HOST}", ${STATIC_PORT}}}]}
]),
%% Boot enough mycelium for the auth callback to find the keypair.
{ok, _} = mycelium_dist_keys:start_link(),
case net_kernel:connect_node('${NODE}') of
    true -> ok;
    ConnErr ->
        io:format(standard_error, "connect failed: ~p~n", [ConnErr]),
        erlang:halt(4)
end,
RpcResult = rpc:call('${NODE}', '${MOD}', '${FUN}', ${ARGS}, ${TIMEOUT}),
_ = (catch rpc:call('${NODE}', erlang, disconnect_node, [node()], 2000)),
case RpcResult of
    {badrpc, BadRpc} ->
        io:format(standard_error, "badrpc: ~p~n", [BadRpc]),
        erlang:halt(5);
    Result ->
        io:format("~p~n", [Result]),
        erlang:halt(0)
end.
ERL
)

ERL_ARGS=(
    -name "$PROBE_NAME"
    -setcookie "$COOKIE"
    -hidden
    -proto_dist quic
    -quic_dist_cert "$CERT"
    -quic_dist_key  "$KEY"
    -quic_dist_port 0
    -kernel net_setuptime 10
    -noinput
)
for d in "${EBINS[@]}"; do
    [[ -d "$d" ]] && ERL_ARGS+=( -pa "$d" )
done

exec erl "${ERL_ARGS[@]}" -eval "$EVAL"
