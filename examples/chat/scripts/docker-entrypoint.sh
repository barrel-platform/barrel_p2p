#!/bin/bash
set -e

# Generate vm.args from environment
cat > /app/releases/0.1.0/vm.args <<EOF
-name ${NODE_NAME}@${HOSTNAME}
-setcookie ${COOKIE}
+K true
+A 10
EOF

# Generate sys.config from environment
CONTACT_NODES_ERLANG="[]"
if [ -n "$CONTACT_NODES" ]; then
    # Convert comma-separated list to Erlang list format
    CONTACT_NODES_ERLANG="[$(echo $CONTACT_NODES | sed "s/,/', '/g" | sed "s/^/'/" | sed "s/$/'/" )]"
fi

cat > /app/releases/0.1.0/sys.config <<EOF
[
    {barrel_p2p, [
        {active_size, 3},
        {passive_size, 10},
        {shuffle_period, 5000},
        {listen_port, 9100},
        {contact_nodes, ${CONTACT_NODES_ERLANG}}
    ]},
    {kernel, [
        {logger_level, info}
    ]}
].
EOF

exec /app/bin/chat "$@"
