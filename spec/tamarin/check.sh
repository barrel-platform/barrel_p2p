#!/usr/bin/env bash
# Prove the distribution auth handshake lemmas with Tamarin.
#
# Each lemma has an expected verdict: "verified" must be proven,
# "falsified" must yield an attack trace (the v2 attacks the v3 protocol
# fixes). The script fails if any verdict differs.
#
# Needs tamarin-prover and maude on PATH (CI installs the pinned releases).
#
# Usage: spec/tamarin/check.sh [Theory:lemma ...]   (default: all below)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

command -v tamarin-prover >/dev/null || { echo "tamarin-prover not on PATH" >&2; exit 1; }
command -v maude >/dev/null || { echo "maude not on PATH" >&2; exit 1; }

# theory  lemma  expected
lemmas=(
    "DistAuthV2  executable                   verified"
    "DistAuthV2  client_authenticates_target  falsified"
    "DistAuthV2  client_agreement             verified"
    "DistAuthV2  server_agreement             falsified"
    "DistAuthV2  dist_name_is_authenticated   falsified"
    "DistAuthV3  executable                   verified"
    "DistAuthV3  client_authenticates_target  verified"
    "DistAuthV3  client_agreement             verified"
    "DistAuthV3  server_agreement             verified"
    "DistAuthV3  client_injective_agreement   verified"
    "DistAuthV3  dist_name_is_authenticated   verified"
)

want=("$@")
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
status=0

for row in "${lemmas[@]}"; do
    read -r theory lemma expected <<<"$row"
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $theory:$lemma " ]]; then
        continue
    fi
    log="$out/$theory.$lemma.log"
    start=$(date +%s)
    tamarin-prover --prove="$lemma" "$here/$theory.spthy" >"$log" 2>&1 || true
    took=$(( $(date +%s) - start ))
    line=$(grep -E "^ +$lemma \((all|exists)-traces\):" "$log" | tail -1 || true)
    case "$line" in
        *verified*) got="verified" ;;
        *falsified*) got="falsified" ;;
        *) got="error" ;;
    esac
    if [ "$got" = "$expected" ]; then
        printf 'ok    %-12s %-30s %-10s %4ss\n' "$theory" "$lemma" "$got" "$took"
    else
        printf 'FAIL  %-12s %-30s expected %s, got %s\n' "$theory" "$lemma" "$expected" "$got"
        tail -30 "$log"
        status=1
    fi
done

exit $status
