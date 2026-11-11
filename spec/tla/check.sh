#!/usr/bin/env bash
# Model-check the barrel_p2p replication specs with TLC.
#
# Each model has an expected verdict: "pass" models must find no error;
# "fail:<Invariant>" models reproduce a known bug and must violate exactly
# that invariant. The script fails if any verdict differs.
#
# Usage: spec/tla/check.sh [model ...]   (default: every model below)
set -euo pipefail

TLA_VERSION="1.7.4"
TLA_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"

here="$(cd "$(dirname "$0")" && pwd)"
cache="${TLA_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/barrel_p2p/tla}"
jar="$cache/tla2tools-$TLA_VERSION.jar"

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ ! -f "$jar" ] || [ "$(sha256 "$jar")" != "$TLA_SHA256" ]; then
    mkdir -p "$cache"
    curl -fsSL -o "$jar.tmp" \
        "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
    if [ "$(sha256 "$jar.tmp")" != "$TLA_SHA256" ]; then
        echo "tla2tools.jar checksum mismatch" >&2
        rm -f "$jar.tmp"
        exit 1
    fi
    mv "$jar.tmp" "$jar"
fi

# model  spec  expected
models=(
    "MergeLattice            MergeLattice  pass"
    "MC_registry             ReplicaORMap  pass"
    "MC_registry_stamp       ReplicaORMap  fail:QuiescentConverged"
    "MC_registry_snap        ReplicaORMap  fail:QuiescentConverged"
    "MC_map                  ReplicaORMap  pass"
    "MC_map_partition        ReplicaORMap  pass"
    "MC_map_partition_stamp  ReplicaORMap  fail:WriterIntentKept"
    "MC_map_snap             ReplicaORMap  fail:QuiescentConverged"
)

want=("$@")
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
status=0

for row in "${models[@]}"; do
    read -r model spec expected <<<"$row"
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $model " ]]; then
        continue
    fi
    log="$out/$model.log"
    start=$(date +%s)
    (cd "$here" && java -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -workers auto -metadir "$out/$model.states" \
        -config "$model.cfg" "$spec.tla") >"$log" 2>&1 || true
    took=$(( $(date +%s) - start ))

    if grep -q "Model checking completed. No error has been found." "$log"; then
        got="pass"
    elif inv=$(grep -oE "Invariant [A-Za-z]+ is (violated|equal to FALSE)" "$log" | head -1); then
        got="fail:$(echo "$inv" | cut -d' ' -f2)"
    elif inv=$(grep -oE "The invariant of [A-Za-z]+ is equal to FALSE" "$log" | head -1); then
        got="fail:$(echo "$inv" | cut -d' ' -f4)"
    else
        got="error"
    fi
    states=$(grep -oE "[0-9]+ distinct states found" "$log" | tail -1 | cut -d' ' -f1 || true)

    if [ "$got" = "$expected" ]; then
        printf 'ok    %-24s %-28s %8s states %4ss\n' "$model" "$got" "${states:-?}" "$took"
    else
        printf 'FAIL  %-24s expected %s, got %s\n' "$model" "$expected" "$got"
        tail -40 "$log"
        status=1
    fi
done

exit $status
