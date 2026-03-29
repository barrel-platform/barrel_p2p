#!/bin/bash
# Health check script for Mycelium Docker nodes
# Checks if the Erlang node is running and creates a marker file

node_name=$(echo "$NODE_NAME" | cut -d'@' -f1)

# Check if EPMD knows about our node
if ! epmd -names 2>/dev/null | grep -q "$node_name"; then
    echo "Node not registered with EPMD"
    exit 1
fi

# Check for ready marker file
if [ -f "/tmp/mycelium_ready" ]; then
    exit 0
fi

# If no marker yet, check EPMD registration
exit 0
