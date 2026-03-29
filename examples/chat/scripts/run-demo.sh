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

case "${1:-}" in
    build)
        echo "Building chat application..."
        rebar3 compile
        echo "Done."
        ;;

    seed)
        echo "Starting seed node..."
        rebar3 shell --sname seed --setcookie chat --eval "chat_client:demo()."
        ;;

    node)
        NODE_NUM="${2:-1}"
        SEED_HOST=$(hostname -s)
        echo "Starting node${NODE_NUM}, joining seed@${SEED_HOST}..."
        rebar3 shell --sname "node${NODE_NUM}" --setcookie chat \
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
