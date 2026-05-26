#!/bin/bash
# Entry point for running Docker-based Ed25519 authentication tests
# Usage:
#   ./docker/scripts/run_auth_tests.sh              # 3-node TOFU test
#   ./docker/scripts/run_auth_tests.sh --no-build   # Skip rebuild
#   ./docker/scripts/run_auth_tests.sh --cleanup    # Cleanup only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker"

# Parse arguments
NO_BUILD=""
CLEANUP_ONLY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-build)
            NO_BUILD="1"
            shift
            ;;
        --cleanup)
            CLEANUP_ONLY="1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--no-build] [--cleanup]"
            exit 1
            ;;
    esac
done

cd "$PROJECT_ROOT"

# Cleanup function
cleanup() {
    echo "Cleaning up auth test containers..."
    docker compose -f docker/docker-compose-auth.yml down --volumes --remove-orphans 2>/dev/null || true
}

# If cleanup only, just run cleanup and exit
if [ -n "$CLEANUP_ONLY" ]; then
    cleanup
    echo "Cleanup complete"
    exit 0
fi

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Clean up any previous run
cleanup

# Create test results directory
mkdir -p "$PROJECT_ROOT/test_results"

echo "========================================"
echo "Barrel P2P Ed25519 Auth Integration Tests"
echo "========================================"
echo "Project root: $PROJECT_ROOT"
echo ""

# Build images
if [ -z "$NO_BUILD" ]; then
    echo "Building Docker images..."
    docker compose -f docker/docker-compose-auth.yml build
else
    echo "Skipping build (--no-build)"
fi

echo ""
echo "Starting cluster with Ed25519 authentication..."
echo ""

# Run the test
# The test_runner service will exit with the test result code
docker compose -f docker/docker-compose-auth.yml up \
    --abort-on-container-exit \
    --exit-code-from test_runner

exit_code=$?

echo ""
echo "========================================"
if [ $exit_code -eq 0 ]; then
    echo "AUTH TESTS PASSED"
else
    echo "AUTH TESTS FAILED (exit code: $exit_code)"
fi
echo "========================================"
echo ""
echo "Test results available at: $PROJECT_ROOT/test_results/"
echo "View HTML report: open $PROJECT_ROOT/test_results/index.html"

exit $exit_code
