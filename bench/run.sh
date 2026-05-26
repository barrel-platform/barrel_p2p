#!/usr/bin/env bash
#
# Run barrel_p2p_sync_bench and emit results as JSON.
#
# Usage:
#   ./bench/run.sh [iterations]
#
# Writes to bench/results.json. Compare against bench/baseline.json with
# bench/compare.sh.

set -eu

ITERATIONS="${1:-1000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/results.json"

cd "$ROOT"

# Snapshot the harness inputs so results can be reproduced.
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')
HOST=$(uname -n)
GIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)

ESCRIPT=$(cat <<'EOF'
case barrel_p2p_sync_bench:run(#{iterations => ITERS}) of
    Results when is_list(Results) ->
        Format = fun({Name, {Total, PerOp}}) ->
            io_lib:format(
              "    \"~s\": {\"total_us\": ~p, \"us_per_op\": ~.4f}",
              [Name, Total, PerOp])
        end,
        Body = string:join([lists:flatten(Format(R)) || R <- Results], ",\n"),
        io:format("BENCH_BEGIN\n{\n~s\n}\nBENCH_END\n", [Body]);
    Other ->
        io:format("BENCH_ERROR: ~p~n", [Other])
end,
init:stop().
EOF
)

ESCRIPT=${ESCRIPT//ITERS/$ITERATIONS}

RAW=$(echo "$ESCRIPT" | rebar3 as test shell --name bench@127.0.0.1 2>&1)

BENCH_BLOCK=$(echo "$RAW" | awk '/BENCH_BEGIN/{flag=1; next} /BENCH_END/{flag=0} flag')

if [ -z "$BENCH_BLOCK" ]; then
    echo "bench/run.sh: no BENCH_BEGIN block in shell output" >&2
    echo "$RAW" >&2
    exit 1
fi

cat > "$OUT" <<JSON
{
  "iterations": $ITERATIONS,
  "otp": "$OTP",
  "host": "$HOST",
  "commit": "$GIT",
  "results":
$BENCH_BLOCK
}
JSON

echo "wrote $OUT"
cat "$OUT"
