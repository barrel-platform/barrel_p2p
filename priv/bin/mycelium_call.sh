#!/usr/bin/env bash
#
# mycelium_call.sh — erl_call-style one-shot RPC over a mycelium
# (-proto_dist quic) cluster, with full Ed25519 dist authentication.
#
# Boots a hidden probe BEAM with mycelium on the path, configures the
# auth callback and discovery module via -quic_dist_* init args, runs
# rpc:call/5 against the target, asks the target to disconnect so the
# hidden-node entry is reaped immediately, and halts.
#
# Usage:
#   mycelium_call.sh [options] <Node> <Module> <Function> [ArgsTerm]
#
# Options (env var fallback in parens):
#   -c, --cookie COOKIE          dist cookie (COOKIE, default mycelium)
#       --cert FILE              TLS cert (MYCELIUM_CERT, default data/quic/node.crt)
#       --key  FILE              TLS key  (MYCELIUM_KEY,  default data/quic/node.key)
#       --key-dir DIR            Ed25519 keypair dir (MYCELIUM_KEY_DIR, default data/keys)
#       --discovery-dir DIR      filesystem-discovery dir (MYCELIUM_DISC_DIR, default data/discovery)
#   -t, --timeout MS             rpc:call timeout (default 10000)
#   -n, --name NAME              probe long node name (default mycelium_call_$$@<host>)
#   -h, --help                   show this help
#
# Exit codes: 0 success, 2 usage error, 4 connect failed, 5 badrpc.

set -euo pipefail

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
}

COOKIE="${COOKIE:-mycelium}"
CERT="${MYCELIUM_CERT:-$PWD/data/quic/node.crt}"
KEY="${MYCELIUM_KEY:-$PWD/data/quic/node.key}"
KEY_DIR="${MYCELIUM_KEY_DIR:-$PWD/data/keys}"
DISC_DIR="${MYCELIUM_DISC_DIR:-$PWD/data/discovery}"
TIMEOUT=10000
NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cookie)         COOKIE="$2"; shift 2 ;;
        --cert)              CERT="$2"; shift 2 ;;
        --key)               KEY="$2"; shift 2 ;;
        --key-dir)           KEY_DIR="$2"; shift 2 ;;
        --discovery-dir)     DISC_DIR="$2"; shift 2 ;;
        -t|--timeout)        TIMEOUT="$2"; shift 2 ;;
        -n|--name)           NAME="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        --)                  shift; break ;;
        -*)                  echo "mycelium_call: unknown option $1" >&2; exit 2 ;;
        *)                   break ;;
    esac
done

if [[ $# -lt 3 ]]; then
    usage >&2
    exit 2
fi

NODE="$1"; MOD="$2"; FUN="$3"; ARGS="${4:-[]}"

for f in "$CERT" "$KEY"; do
    if [[ ! -r "$f" ]]; then
        echo "mycelium_call: file not readable: $f" >&2
        exit 2
    fi
done

# Resolve script dir and walk up to a rebar3 _build/default/lib tree.
# We support both layouts:
#   1) installed under .../mycelium/priv/bin/  (rebar3-compiled)
#   2) checked-out source tree at /Users/.../erlang-mycelium/priv/bin/
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *)  SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Possible roots: priv/bin -> mycelium app dir
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Find the surrounding _build/default/lib so we can -pa each dep.
LIB_DIR=""
SEARCH_DIR="$APP_DIR"
for _ in 1 2 3 4 5 6; do
    if [[ -d "$SEARCH_DIR/_build/default/lib" ]]; then
        LIB_DIR="$SEARCH_DIR/_build/default/lib"
        break
    fi
    SEARCH_DIR="$(dirname "$SEARCH_DIR")"
done

PA_ARGS=()
if [[ -n "$LIB_DIR" ]]; then
    for d in "$LIB_DIR"/*/ebin; do
        [[ -d "$d" ]] && PA_ARGS+=( -pa "$d" )
    done
fi
# Always include the mycelium app's own ebin (when running from a
# checkout it lives at $APP_DIR/ebin after compile).
[[ -d "$APP_DIR/ebin" ]] && PA_ARGS+=( -pa "$APP_DIR/ebin" )

if [[ -z "$NAME" ]]; then
    NAME="mycelium_call_$$@$(hostname -s)"
fi

EVAL=$(cat <<ERL
ok = application:load(mycelium),
ok = application:set_env(mycelium, auth_enabled,    true),
ok = application:set_env(mycelium, auth_key_dir,    "${KEY_DIR}"),
ok = application:set_env(mycelium, auth_trust_mode, tofu),
ok = application:set_env(mycelium, discovery_dir,   "${DISC_DIR}"),
ok = application:set_env(mycelium, discovery_backends,
    [mycelium_discovery_static,
     mycelium_discovery_file,
     mycelium_discovery_dns]),
%% Make sure the probe shares the seed's view of the {quic, dist}
%% block so the lookup path resolves the discovery_module correctly.
DistOpts0 = application:get_env(quic, dist, []),
DistOpts1 = lists:keystore(discovery_module, 1, DistOpts0,
                           {discovery_module, mycelium_discovery}),
DistOpts2 = lists:keystore(auth_callback, 1, DistOpts1,
                           {auth_callback,
                            {mycelium_dist_auth_callback, authenticate}}),
ok = application:set_env(quic, dist, DistOpts2),
{ok, _} = mycelium_dist_keys:start_link(),
case net_kernel:connect_node('${NODE}') of
    true -> ok;
    Err  ->
        io:format(standard_error, "connect failed: ~p~n", [Err]),
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
    -name "$NAME"
    -setcookie "$COOKIE"
    -hidden
    -noinput
    -proto_dist quic
    -epmd_module quic_epmd
    -start_epmd false
    -quic_dist_cert "$CERT"
    -quic_dist_key  "$KEY"
    -quic_dist_port 0
    -quic_dist_discovery_module mycelium_discovery
    -quic_dist_auth_callback    mycelium_dist_auth_callback:authenticate
    -kernel net_setuptime 10
)
ERL_ARGS+=( "${PA_ARGS[@]}" )

exec erl "${ERL_ARGS[@]}" -eval "$EVAL"
