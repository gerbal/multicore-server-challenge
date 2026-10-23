#!/usr/bin/env bash
# One measured load-test point against a release of this submission (or a variant copy of it).
#
#   [ENV=...] tuning/bench.sh <label> <users>
#
# For each call: a fresh database copied from $TEMPLATE, the release started with the caller's environment (so
# DB_POOL_SIZE, ERL_AFLAGS and any experiment switches pass straight through), a short warm-up, then one measured
# run of bench/cmd/loadgen. It prints one summary line and appends it to $OUT/results.txt.
#
# The CPU columns are the most stable numbers when the load generator shares the machine: app_ms/req and pg_ms/req
# are BEAM and Postgres CPU per request over exactly the measured window, from /proc tick counters.
#
# Settings (environment):
#   APP          release to test (default: this submission). Build it first with its build.sh.
#   OUT          where results go (default: ./tuning-results)
#   TEMPLATE     seed database to copy (default: conduit_dev; conduit_seed is the full benchmark seed)
#   ARTICLES     articles in the seed (default: 10000 for conduit_dev, 500000 otherwise)
#   THINK_SCALE  loadgen -think-scale (default 0.2: each user makes ~5x a real user's requests; use 1 for real pacing)
#   RAMP MEASURE TAIL  seconds (default 15, 30, 5); WARMUP_USERS (default 300)
#   PORT         server port (default 3110); PGHOST PGPORT PGUSER PGPASSWORD for a Postgres superuser
#
# Caution: never pass the loadgen `-out /dev/null`. It writes results via a rename, which as root replaces the
# /dev/null device with a regular file.
set -uo pipefail
label=${1:?usage: bench.sh <label> <users>} users=${2:?usage: bench.sh <label> <users>}

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
APP=${APP:-$(cd "$HERE/.." && pwd)}
OUT=${OUT:-$PWD/tuning-results}
TEMPLATE=${TEMPLATE:-conduit_dev}
if [ "$TEMPLATE" = conduit_dev ]; then ARTICLES=${ARTICLES:-10000}; else ARTICLES=${ARTICLES:-500000}; fi
THINK_SCALE=${THINK_SCALE:-0.2} RAMP=${RAMP:-15} MEASURE=${MEASURE:-30} TAIL=${TAIL:-5}
WARMUP_USERS=${WARMUP_USERS:-300} PORT=${PORT:-3110}
export PGHOST=${PGHOST:-127.0.0.1} PGUSER=${PGUSER:-postgres}
mkdir -p "$OUT"

LG=${LG:-$OUT/loadgen}
[ -x "$LG" ] || (cd "$REPO/bench" && go build -o "$LG" ./cmd/loadgen) || { echo "cannot build loadgen"; exit 1; }
[ -x "$APP/_build/prod/rel/conduit/bin/conduit" ] || { echo "no release in $APP: run $APP/build.sh"; exit 1; }

HZ=$(getconf CLK_TCK)
ticks() { local t=0 s; for p in $(pgrep -f "$1"); do s=$(cut -d' ' -f14,15 /proc/$p/stat 2>/dev/null) && t=$((t + ${s% *} + ${s#* })); done; echo $t; }
stop_app() { pkill -f "$APP/_build/prod/rel/conduit/erts"; sleep 1; }

stop_app
psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit_lg WITH (FORCE)" \
  -c "CREATE DATABASE conduit_lg TEMPLATE $TEMPLATE STRATEGY FILE_COPY" || { echo "cannot create database"; exit 1; }

DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=$PORT \
  bash "$APP/start.sh" > "$OUT/server-$label.log" 2>&1 &
for _ in $(seq 120); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.5; done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" || { echo "server did not start; see $OUT/server-$label.log"; exit 1; }

lg() { "$LG" run -target "http://127.0.0.1:$PORT" -secret dev-secret -articles "$ARTICLES" -think-scale "$THINK_SCALE" \
  -run-id "$1$(date +%s%N)" "${@:2}"; }
lg w -users "$WARMUP_USERS" -ramp 5s -measure 15s -tail 2s -q -out "$OUT/warmup.json" > /dev/null 2>&1
sleep 3

# The loadgen starts its ramp 2 s after launch; sample CPU over exactly the measured window.
( sleep $((2 + RAMP)); echo "$(ticks beam.smp) $(ticks 'postgres: ')" > "$OUT/.t0"
  sleep "$MEASURE"; echo "$(ticks beam.smp) $(ticks 'postgres: ')" > "$OUT/.t1" ) &
sampler=$!
lg m -users "$users" -ramp "${RAMP}s" -measure "${MEASURE}s" -tail "${TAIL}s" \
  -out "$OUT/$label-$users.json" > "$OUT/$label-$users.txt" 2>&1
wait $sampler
read -r b0 p0 < "$OUT/.t0"; read -r b1 p1 < "$OUT/.t1"
stop_app

read -r _ count rps p50 p90 p95 p99 max err <<< "$(grep '^ALL' "$OUT/$label-$users.txt")"
line=$(printf '%-22s users=%-6s req/s=%-8s p50=%-7s p95=%-7s p99=%-7s err%%=%-6s app_ms/req=%.3f pg_ms/req=%.3f app_cores=%.2f pg_cores=%.2f' \
  "$label" "$users" "$rps" "$p50" "$p95" "$p99" "$err" \
  "$(echo "($b1-$b0)*1000/$HZ/($rps*$MEASURE)" | bc -l)" "$(echo "($p1-$p0)*1000/$HZ/($rps*$MEASURE)" | bc -l)" \
  "$(echo "($b1-$b0)/$HZ/$MEASURE" | bc -l)" "$(echo "($p1-$p0)/$HZ/$MEASURE" | bc -l)")
echo "$line" | tee -a "$OUT/results.txt"
