#!/bin/bash
#
# Test the chat example using Docker Compose
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$CHAT_DIR"

echo "=== Building Docker images ==="
docker compose build

echo ""
echo "=== Starting cluster ==="
docker compose up -d

echo ""
echo "=== Waiting for nodes to start ==="
sleep 5

echo ""
echo "=== Cluster status ==="
docker compose ps

echo ""
echo "=== Testing cluster connectivity ==="

# Create a room on seed node
echo "Creating room on seed node..."
docker compose exec -T seed /app/bin/chat eval "chat_room_sup:create_room(test_room)."

sleep 2

# Check rooms from node1
echo "Checking rooms from node1..."
docker compose exec -T node1 /app/bin/chat eval "chat_server:list_rooms()."

# Check active view on each node
echo ""
echo "=== Checking cluster membership ==="
for node in seed node1 node2 node3; do
    echo "Active view on $node:"
    docker compose exec -T $node /app/bin/chat eval "mycelium:active_view()." 2>/dev/null || echo "  (node not ready)"
done

echo ""
echo "=== Interactive testing ==="
echo "To attach to a node:"
echo "  docker compose exec seed /app/bin/chat remote_console"
echo ""
echo "In the console, try:"
echo "  chat_client:demo()."
echo "  mycelium:active_view()."
echo "  chat_server:list_rooms()."
echo ""
echo "To stop the cluster:"
echo "  docker compose down"
