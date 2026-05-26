#!/bin/bash
set -e

# Entrypoint for barrel_p2p docker integration tests.
# Roles: seed, strict_seed, member, auth_test_runner.
#
# Barrel P2P runs on top of upstream `quic_dist'. The Ed25519 identity
# protocol is exposed as a `quic_dist_auth' callback in
# `barrel_p2p_dist_auth_callback'. Cert/key files are auto-generated
# under /app/data/quic before the BEAM is started so quic_dist:listen
# can load them.

export HOME=/tmp

# Set cookie
if [ -n "$ERLANG_COOKIE" ]; then
    echo "$ERLANG_COOKIE" > "$HOME/.erlang.cookie"
    chmod 400 "$HOME/.erlang.cookie"
fi

# Setup auth key directory
setup_auth_keys() {
    local key_dir="/app/data/keys"
    mkdir -p "$key_dir/trusted"
    chmod 700 "$key_dir"
}

# Generate the self-signed TLS material that quic_dist needs to listen.
# Idempotent; barrel_p2p_quic_cert:ensure_cert/0 only writes new files
# when they are missing.
ensure_quic_cert() {
    local cert_dir="/app/data/quic"
    mkdir -p "$cert_dir"
    erl -noshell -pa /app/_build/test/lib/*/ebin \
        -eval "
            {ok, _} = application:ensure_all_started(public_key),
            application:load(barrel_p2p),
            application:set_env(barrel_p2p, quic_cert_dir, \"$cert_dir\"),
            ok = barrel_p2p_quic_cert:ensure_cert(),
            halt(0).
        "
}

# Wait for a node to be reachable (check if we can ping it)
wait_for_node() {
    local node_host="$1"
    local max_attempts=60
    local attempt=1

    echo "Waiting for node $node_host to be reachable..."
    while ! ping -c 1 "$node_host" > /dev/null 2>&1; do
        if [ $attempt -ge $max_attempts ]; then
            echo "ERROR: Node $node_host not reachable after $max_attempts attempts"
            exit 1
        fi
        echo "Waiting for node $node_host... (attempt $attempt)"
        sleep 1
        ((attempt++))
    done
    echo "Node $node_host is reachable"
    # The cluster runs with -proto_dist barrel_p2p and the barrel_p2p_epmd
    # discovery module, so there is no stock EPMD on port 4369 to poll.
    # Docker compose's `service_healthy` dependency (driven by
    # /app/scripts/health_check.sh) is the real readiness gate.
}

# Start an Erlang node with -proto_dist barrel_p2p.
dist_port_for() {
    # Pinned ports keep cluster-topology.config's static discovery
    # entries valid across runs.
    case "$1" in
        node1) echo 9101 ;;
        node2) echo 9102 ;;
        node3) echo 9103 ;;
        *)     echo 0 ;;
    esac
}

start_node() {
    local name="$1"
    local contact_node="$2"

    local contact_config=""
    if [ -n "$contact_node" ]; then
        contact_config="-barrel_p2p contact_nodes ['$contact_node']"
    fi

    local short_name
    short_name=$(echo "$name" | cut -d'@' -f1)
    local dist_port
    dist_port=$(dist_port_for "$short_name")

    echo "Starting node: $name (short: $short_name, port: $dist_port)"
    echo "Contact node: ${contact_node:-none}"
    echo "Auth enabled: ${AUTH_ENABLED:-false}"
    echo "Auth trust mode: ${AUTH_TRUST_MODE:-tofu}"

    local auth_config=""
    if [ "$AUTH_ENABLED" = "true" ]; then
        setup_auth_keys
        auth_config="-barrel_p2p auth_enabled true -barrel_p2p auth_key_dir '\"/app/data/keys\"' -barrel_p2p auth_trust_mode ${AUTH_TRUST_MODE:-tofu}"
    else
        auth_config="-barrel_p2p auth_enabled false"
    fi

    local whitelist_config=""
    if [ -n "$COOKIE_ONLY_NODES" ]; then
        whitelist_config="-barrel_p2p cookie_only_nodes [$COOKIE_ONLY_NODES]"
    fi

    local dist_cookie_config=""
    if [ -n "$DIST_COOKIE" ]; then
        dist_cookie_config="-barrel_p2p dist_cookie $DIST_COOKIE"
    fi

    local startup_eval
    if [ -n "$contact_node" ]; then
        startup_eval="
            application:ensure_all_started(barrel_p2p),
            file:write_file(\"/tmp/barrel_p2p_ready\", <<>>),
            JoinFun = fun JoinLoop(0) ->
                io:format(\"Failed to join cluster after retries~n\"),
                ok;
            JoinLoop(N) ->
                case barrel_p2p:join('$contact_node') of
                    ok ->
                        io:format(\"Successfully joined $contact_node~n\"),
                        ok;
                    {error, _} ->
                        timer:sleep(1000),
                        JoinLoop(N - 1)
                end
            end,
            timer:sleep(2000),
            JoinFun(30)
        "
    else
        startup_eval="application:ensure_all_started(barrel_p2p), file:write_file(\"/tmp/barrel_p2p_ready\", <<>>)"
    fi

    echo "Cookie only nodes: ${COOKIE_ONLY_NODES:-none}"
    echo "Dist cookie: ${DIST_COOKIE:-default}"

    ensure_quic_cert

    exec erl \
        -sname "$short_name" \
        -setcookie "$ERLANG_COOKIE" \
        -pa /app/_build/test/lib/*/ebin \
        -config /app/docker/cluster-topology \
        $auth_config \
        $whitelist_config \
        $dist_cookie_config \
        $contact_config \
        -proto_dist barrel_p2p \
        -epmd_module barrel_p2p_epmd \
        -start_epmd false \
        -barrel_p2p_dist_port "$dist_port" \
        -eval "$startup_eval" \
        -noshell
}

# Run authentication tests
run_auth_tests() {
    echo "Starting auth test runner"
    echo "Test nodes: $TEST_NODES"

    if [ "$AUTH_ENABLED" = "true" ]; then
        setup_auth_keys
    fi

    for node in $(echo "$TEST_NODES" | tr ',' ' '); do
        host=$(echo "$node" | cut -d'@' -f2)
        wait_for_node "$host"
    done

    echo "Waiting for cluster to form and authenticate..."
    sleep 15

    mkdir -p /app/test_results

    local auth_config=""
    if [ "$AUTH_ENABLED" = "true" ]; then
        auth_config="-barrel_p2p auth_enabled true -barrel_p2p auth_key_dir '\"/app/data/keys\"' -barrel_p2p auth_trust_mode ${AUTH_TRUST_MODE:-tofu}"
    fi

    echo "Running authentication tests..."
    cd /app

    # Pre-provision the test_runner's Ed25519 keypair into the same
    # auth_key_dir the cluster nodes use. barrel_p2p_dist_auth_stream
    # reads node.pub/node.key directly off disk on every dist
    # handshake, and the test_runner does not start the barrel_p2p app
    # (so barrel_p2p_dist_keys never auto-generates them).
    if [ "$AUTH_ENABLED" = "true" ]; then
        erl -noshell -pa /app/_build/test/lib/*/ebin \
            -eval "
                {ok, _} = application:ensure_all_started(crypto),
                application:load(barrel_p2p),
                application:set_env(barrel_p2p, auth_key_dir, \"/app/data/keys\"),
                ok = barrel_p2p_dist_auth:ensure_keypair(),
                halt(0).
            "
    fi

    ensure_quic_cert

    erl \
        -sname test_runner \
        -hidden \
        -setcookie ${DIST_COOKIE:-barrel_p2p} \
        -pa /app/_build/test/lib/*/ebin \
        -config /app/docker/cluster-topology \
        $auth_config \
        -proto_dist barrel_p2p \
        -epmd_module barrel_p2p_epmd \
        -start_epmd false \
        -noshell \
        -eval "
            application:load(barrel_p2p),
            application:set_env(barrel_p2p, auth_enabled, true),
            application:set_env(barrel_p2p, auth_key_dir, \"/app/data/keys\"),
            application:set_env(barrel_p2p, auth_trust_mode, tofu),
            %% barrel_p2p_dist_keys is the gen_server that records TOFU
            %% pubkeys from each peer. Without it, the auth handshake
            %% reaches store_key_if_new and crashes with noproc.
            {ok, _} = barrel_p2p_dist_keys:start_link(),
            os:putenv(\"TEST_NODES\", \"$TEST_NODES\"),
            case ct:run_test([
                {suite, barrel_p2p_docker_auth_SUITE},
                {dir, \"/app/test\"},
                {logdir, \"/app/test_results\"},
                {config, \"/app/docker/cluster-topology.config\"}
            ]) of
                {Ok, 0, {_UserSkip, 0}} ->
                    io:format(\"~n~nAll auth tests passed (~p ok)~n\", [Ok]),
                    init:stop(0);
                {_Ok, Failed, _} when Failed > 0 ->
                    io:format(\"~n~nFailed auth tests: ~p~n\", [Failed]),
                    init:stop(1);
                {_Ok, 0, {_, A}} when A > 0 ->
                    io:format(\"~n~nAuto-skipped auth tests: ~p (init failure)~n\", [A]),
                    init:stop(1);
                Error ->
                    io:format(\"~n~nAuth test error: ~p~n\", [Error]),
                    init:stop(1)
            end.
        "

    exit_code=$?
    echo "Auth tests completed with exit code: $exit_code"
    exit $exit_code
}

# Main
case "$NODE_ROLE" in
    seed)
        start_node "$NODE_NAME" ""
        ;;
    strict_seed)
        start_node "$NODE_NAME" ""
        ;;
    member)
        if [ -n "$CONTACT_NODE" ]; then
            contact_host=$(echo "$CONTACT_NODE" | cut -d'@' -f2)
            wait_for_node "$contact_host"
        fi
        start_node "$NODE_NAME" "$CONTACT_NODE"
        ;;
    auth_test_runner)
        run_auth_tests
        ;;
    *)
        echo "Unknown role: $NODE_ROLE"
        echo "Use: seed, member, auth_test_runner, or strict_seed"
        exit 1
        ;;
esac
