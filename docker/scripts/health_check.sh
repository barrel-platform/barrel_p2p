#!/bin/bash
# Health check script for Mycelium Docker nodes.
#
# Nodes run with -proto_dist mycelium and the mycelium_epmd module,
# so the stock `epmd -names` will never show them. The mycelium app
# writes /tmp/mycelium_ready once it has started.

if [ -f "/tmp/mycelium_ready" ]; then
    exit 0
fi

echo "Mycelium not ready (no /tmp/mycelium_ready marker)"
exit 1
