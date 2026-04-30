#!/bin/bash
set -e

# Entrypoint script for Mycelium nodes
# Handles different roles: seed, member, test_runner, auth_test_runner, strict_seed

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

    # Also wait for EPMD on that host
    attempt=1
    while ! nc -z "$node_host" 4369 2>/dev/null; do
        if [ $attempt -ge $max_attempts ]; then
            echo "ERROR: EPMD on $node_host not available after $max_attempts attempts"
            exit 1
        fi
        echo "Waiting for EPMD on $node_host... (attempt $attempt)"
        sleep 1
        ((attempt++))
    done
    echo "EPMD on $node_host is available"
}

# Start Erlang node
start_node() {
    local name="$1"
    local contact_node="$2"

    # Build contact_nodes config
    local contact_config=""
    if [ -n "$contact_node" ]; then
        contact_config="-mycelium contact_nodes ['$contact_node']"
    fi

    local short_name
    short_name=$(echo "$name" | cut -d'@' -f1)

    echo "Starting node: $name (short: $short_name)"
    echo "Contact node: ${contact_node:-none}"
    echo "Auth enabled: ${AUTH_ENABLED:-false}"
    echo "Auth trust mode: ${AUTH_TRUST_MODE:-tofu}"

    # Build auth config. Default to auth_enabled=false so the basic
    # integration test (whose test_runner does not provision keys) can
    # RPC into the cluster. The auth and circuit suites set
    # AUTH_ENABLED=true explicitly via compose.
    local auth_config=""
    if [ "$AUTH_ENABLED" = "true" ]; then
        setup_auth_keys
        auth_config="-mycelium auth_enabled true -mycelium auth_key_dir '\"/app/data/keys\"' -mycelium auth_trust_mode ${AUTH_TRUST_MODE:-tofu}"
    else
        auth_config="-mycelium auth_enabled false"
    fi

    # Build encryption config
    local encryption_config=""
    if [ "$ENCRYPTION_ENABLED" = "true" ]; then
        encryption_config="-mycelium encryption_enabled true"
    elif [ "$ENCRYPTION_ENABLED" = "false" ]; then
        encryption_config="-mycelium encryption_enabled false"
    fi

    # Build whitelist config if provided
    local whitelist_config=""
    if [ -n "$COOKIE_ONLY_NODES" ]; then
        whitelist_config="-mycelium cookie_only_nodes [$COOKIE_ONLY_NODES]"
    fi

    # Build dist_cookie config (to match what mycelium sets)
    local dist_cookie_config=""
    if [ -n "$DIST_COOKIE" ]; then
        dist_cookie_config="-mycelium dist_cookie $DIST_COOKIE"
    fi

    # Build the startup eval with join retry logic
    local startup_eval
    if [ -n "$contact_node" ]; then
        # Retry join up to 30 times (30 seconds)
        startup_eval="
            application:ensure_all_started(mycelium),
            file:write_file(\"/tmp/mycelium_ready\", <<>>),
            JoinFun = fun JoinLoop(0) ->
                io:format(\"Failed to join cluster after retries~n\"),
                ok;
            JoinLoop(N) ->
                case mycelium:join('$contact_node') of
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
        startup_eval="application:ensure_all_started(mycelium), file:write_file(\"/tmp/mycelium_ready\", <<>>)"
    fi

    echo "Encryption enabled: ${ENCRYPTION_ENABLED:-default}"
    echo "Cookie only nodes: ${COOKIE_ONLY_NODES:-none}"
    echo "Dist cookie: ${DIST_COOKIE:-default}"

    # Use mycelium's own proto_dist (OTP appends "_dist" -> mycelium_dist).
    local proto_dist_config="-proto_dist mycelium"

    exec erl \
        -sname "$short_name" \
        -setcookie "$ERLANG_COOKIE" \
        -pa /app/_build/test/lib/*/ebin \
        -config /app/config/sys \
        $auth_config \
        $encryption_config \
        $whitelist_config \
        $dist_cookie_config \
        $proto_dist_config \
        -eval "$startup_eval" \
        -noshell
}

# Run integration tests
run_tests() {
    echo "Starting test runner"
    echo "Test nodes: $TEST_NODES"

    # Wait for all test nodes to be reachable
    for node in $(echo "$TEST_NODES" | tr ',' ' '); do
        host=$(echo "$node" | cut -d'@' -f2)
        wait_for_node "$host"
    done

    # Give nodes extra time to form cluster
    echo "Waiting for cluster to form..."
    sleep 10

    # Create test results directory
    mkdir -p /app/test_results

    # Run CT suite
    echo "Running integration tests..."
    cd /app

    # Cluster nodes set their cookie to 'mycelium' inside mycelium_app:start.
    # Match it on the test_runner so the dist handshake succeeds.
    erl \
        -sname test_runner \
        -hidden \
        -setcookie mycelium \
        -pa /app/_build/test/lib/*/ebin \
        -config /app/docker/test.config \
        -proto_dist mycelium \
        -noshell \
        -eval "
            application:load(mycelium),
            application:set_env(mycelium, auth_enabled, false),
            os:putenv(\"TEST_NODES\", \"$TEST_NODES\"),
            case ct:run_test([
                {suite, mycelium_integration_SUITE},
                {dir, \"/app/test\"},
                {logdir, \"/app/test_results\"},
                {config, \"/app/docker/test.config\"}
            ]) of
                {Ok, 0, {0, 0}} ->
                    io:format(\"~n~nAll tests passed (~p)~n\", [Ok]),
                    init:stop(0);
                {_Ok, Failed, _} when Failed > 0 ->
                    io:format(\"~n~nFailed tests: ~p~n\", [Failed]),
                    init:stop(1);
                {_Ok, 0, {U, A}} when U + A > 0 ->
                    io:format(\"~n~nUnexpected skips: user=~p auto=~p~n\", [U, A]),
                    init:stop(1);
                Error ->
                    io:format(\"~n~nTest error: ~p~n\", [Error]),
                    init:stop(1)
            end.
        "

    exit_code=$?
    echo "Tests completed with exit code: $exit_code"
    exit $exit_code
}

# Run authentication tests
run_auth_tests() {
    echo "Starting auth test runner"
    echo "Test nodes: $TEST_NODES"

    # Setup auth keys for test runner
    if [ "$AUTH_ENABLED" = "true" ]; then
        setup_auth_keys
    fi

    # Wait for all test nodes to be reachable
    for node in $(echo "$TEST_NODES" | tr ',' ' '); do
        host=$(echo "$node" | cut -d'@' -f2)
        wait_for_node "$host"
    done

    # Give nodes extra time to form cluster and authenticate
    echo "Waiting for cluster to form and authenticate..."
    sleep 15

    # Create test results directory
    mkdir -p /app/test_results

    # Build auth config for test runner
    local auth_config=""
    if [ "$AUTH_ENABLED" = "true" ]; then
        auth_config="-mycelium auth_enabled true -mycelium auth_key_dir '\"/app/data/keys\"' -mycelium auth_trust_mode ${AUTH_TRUST_MODE:-tofu}"
    fi

    # Run CT suite
    echo "Running authentication tests..."
    cd /app

    erl \
        -sname test_runner \
        -hidden \
        -setcookie "$ERLANG_COOKIE" \
        -pa /app/_build/test/lib/*/ebin \
        -config /app/docker/auth-test.config \
        $auth_config \
        -proto_dist mycelium \
        -noshell \
        -eval "
            os:putenv(\"TEST_NODES\", \"$TEST_NODES\"),
            case ct:run_test([
                {suite, mycelium_docker_auth_SUITE},
                {dir, \"/app/test\"},
                {logdir, \"/app/test_results\"},
                {config, \"/app/docker/auth-test.config\"}
            ]) of
                {Ok, 0, {0, 0}} ->
                    io:format(\"~n~nAll auth tests passed (~p)~n\", [Ok]),
                    init:stop(0);
                {_Ok, Failed, _} when Failed > 0 ->
                    io:format(\"~n~nFailed auth tests: ~p~n\", [Failed]),
                    init:stop(1);
                {_Ok, 0, {U, A}} when U + A > 0 ->
                    io:format(\"~n~nUnexpected auth skips: user=~p auto=~p~n\", [U, A]),
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

# Run circuit tests
run_circuit_tests() {
    echo "Starting circuit test runner"
    echo "Test nodes: $TEST_NODES"

    # Setup auth keys for test runner
    if [ "$AUTH_ENABLED" = "true" ]; then
        setup_auth_keys
    fi

    # Wait for all test nodes to be reachable
    for node in $(echo "$TEST_NODES" | tr ',' ' '); do
        host=$(echo "$node" | cut -d'@' -f2)
        wait_for_node "$host"
    done

    # Give nodes extra time to form cluster and establish circuits
    echo "Waiting for cluster to form and stabilize..."
    sleep 20

    # Create test results directory
    mkdir -p /app/test_results

    # Build auth config for test runner
    local auth_config=""
    if [ "$AUTH_ENABLED" = "true" ]; then
        auth_config="-mycelium auth_enabled true -mycelium auth_key_dir '\"/app/data/keys\"' -mycelium auth_trust_mode ${AUTH_TRUST_MODE:-tofu}"
    fi

    # Build encryption config
    local encryption_config=""
    if [ "$ENCRYPTION_ENABLED" = "true" ]; then
        encryption_config="-mycelium encryption_enabled true"
    fi

    # Run CT suite
    echo "Running circuit tests..."
    cd /app

    erl \
        -sname test_runner \
        -hidden \
        -setcookie "$ERLANG_COOKIE" \
        -pa /app/_build/test/lib/*/ebin \
        -config /app/docker/circuit-test.config \
        $auth_config \
        $encryption_config \
        -proto_dist mycelium \
        -noshell \
        -eval "
            os:putenv(\"TEST_NODES\", \"$TEST_NODES\"),
            case ct:run_test([
                {suite, mycelium_docker_circuit_SUITE},
                {dir, \"/app/test\"},
                {logdir, \"/app/test_results\"},
                {config, \"/app/docker/circuit-test.config\"}
            ]) of
                {Ok, 0, {0, 0}} ->
                    io:format(\"~n~nCircuit tests: ~p passed, 0 failed~n\", [Ok]),
                    init:stop(0);
                {_Ok, Failed, _} when Failed > 0 ->
                    io:format(\"~n~nFailed circuit tests: ~p~n\", [Failed]),
                    init:stop(1);
                {_Ok, 0, {U, A}} when U + A > 0 ->
                    io:format(\"~n~nUnexpected circuit skips: user=~p auto=~p~n\", [U, A]),
                    init:stop(1);
                Error ->
                    io:format(\"~n~nCircuit test error: ~p~n\", [Error]),
                    init:stop(1)
            end.
        "

    exit_code=$?
    echo "Circuit tests completed with exit code: $exit_code"
    exit $exit_code
}

# Main
case "$NODE_ROLE" in
    seed)
        start_node "$NODE_NAME" ""
        ;;
    strict_seed)
        # Seed node in strict mode
        start_node "$NODE_NAME" ""
        ;;
    member)
        # Wait for contact node
        if [ -n "$CONTACT_NODE" ]; then
            contact_host=$(echo "$CONTACT_NODE" | cut -d'@' -f2)
            wait_for_node "$contact_host"
        fi
        start_node "$NODE_NAME" "$CONTACT_NODE"
        ;;
    test_runner)
        run_tests
        ;;
    auth_test_runner)
        run_auth_tests
        ;;
    circuit_test_runner)
        run_circuit_tests
        ;;
    *)
        echo "Unknown role: $NODE_ROLE"
        echo "Use: seed, member, test_runner, auth_test_runner, circuit_test_runner, or strict_seed"
        exit 1
        ;;
esac
