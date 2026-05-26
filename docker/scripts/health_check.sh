#!/bin/bash
# Health check script for Barrel P2P Docker nodes.
#
# Nodes run with -proto_dist barrel_p2p and the barrel_p2p_epmd module,
# so the stock `epmd -names` will never show them. The barrel_p2p app
# writes /tmp/barrel_p2p_ready once it has started.

if [ -f "/tmp/barrel_p2p_ready" ]; then
    exit 0
fi

echo "Barrel P2P not ready (no /tmp/barrel_p2p_ready marker)"
exit 1
