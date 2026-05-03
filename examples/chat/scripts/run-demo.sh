#!/bin/bash
#
# Interactive demo runner for the chat example
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  build       Build the chat application"
    echo "  seed        Start the seed node"
    echo "  node <n>    Start node n (joins seed)"
    echo "  docker-up   Start Docker cluster"
    echo "  docker-down Stop Docker cluster"
    echo "  docker-logs View Docker logs"
    echo "  clean       Clean build artifacts"
    echo ""
}

cd "$CHAT_DIR"

# Ensure checkouts symlink exists for local development
if [ ! -L "_checkouts/mycelium" ]; then
    mkdir -p _checkouts
    ln -sf ../../.. _checkouts/mycelium
fi

# Ensure mycelium is linked in _build for rebar3 shell
if [ -d "_build/default/lib" ] && [ ! -e "_build/default/lib/mycelium" ]; then
    ln -sf ../../../_checkouts/mycelium/_build/default/lib/mycelium _build/default/lib/mycelium
fi

# Pre-generate the QUIC TLS cert if missing. The kernel app starts
# distribution before mycelium_app:start/2 runs, so the cert MUST
# exist on disk at boot — quic_dist:listen/2 fails otherwise. The
# Ed25519 identity keypair under data/keys/ is generated lazily by
# mycelium_dist_keys on first start; no setup needed.
ensure_cert() {
    if [ ! -f data/quic/node.crt ] || [ ! -f data/quic/node.key ]; then
        echo "Generating QUIC TLS cert in data/quic/ ..."
        rebar3 compile >/dev/null
        erl -noshell \
            -pa _build/default/lib/*/ebin \
            -eval 'application:load(mycelium), mycelium_quic_cert:ensure_cert("data/quic"), halt().'
    fi
}

case "${1:-}" in
    build)
        echo "Building chat application..."
        rebar3 compile
        ensure_cert
        echo "Done."
        ;;

    seed)
        ensure_cert
        echo "Starting seed node..."
        rebar3 shell --sname seed --setcookie chat \
            --erl_args "-proto_dist quic" \
            --eval "chat_client:demo()."
        ;;

    node)
        ensure_cert
        NODE_NUM="${2:-1}"
        SEED_HOST=$(hostname -s)
        echo "Starting node${NODE_NUM}, joining seed@${SEED_HOST}..."
        rebar3 shell --sname "node${NODE_NUM}" --setcookie chat \
            --erl_args "-proto_dist quic" \
            --eval "mycelium:join('seed@${SEED_HOST}'), {ok, C} = chat_client:start(), timer:sleep(500), chat_client:join(demo_room, C)."
        ;;

    docker-up)
        echo "Starting Docker cluster..."
        docker compose up -d
        echo "Waiting for startup..."
        sleep 5
        docker compose ps
        echo ""
        echo "Attach to seed: docker compose exec seed /app/bin/chat remote_console"
        ;;

    docker-down)
        echo "Stopping Docker cluster..."
        docker compose down
        ;;

    docker-logs)
        docker compose logs -f
        ;;

    clean)
        echo "Cleaning build artifacts..."
        rm -rf _build
        docker compose down --rmi local 2>/dev/null || true
        echo "Done."
        ;;

    *)
        usage
        exit 1
        ;;
esac
