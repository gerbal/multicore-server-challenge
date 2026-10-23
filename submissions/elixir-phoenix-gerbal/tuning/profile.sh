#!/usr/bin/env bash
# Profiles the prod build under load with :tprof (call_time tracing of every function) for 10 s, and writes the
# top modules and functions by time to $OUT/profile-mods.txt and $OUT/profile-funs.txt.
#
#   [USERS=500] [OUT=...] tuning/profile.sh
#
# The release has no distribution and doesn't include OTP's tools application, so this runs the prod build through
# `mix run` as a named node instead, and tuning/prof.exs attaches from a second node. Tracing slows everything down,
# so read the output as proportions, not absolute costs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
APP=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$PWD/tuning-results} USERS=${USERS:-500} TEMPLATE=${TEMPLATE:-conduit_dev} PORT=${PORT:-3110}
if [ "$TEMPLATE" = conduit_dev ]; then ARTICLES=${ARTICLES:-10000}; else ARTICLES=${ARTICLES:-500000}; fi
export PGHOST=${PGHOST:-127.0.0.1} PGUSER=${PGUSER:-postgres}
mkdir -p "$OUT"
LG=${LG:-$OUT/loadgen}
[ -x "$LG" ] || (cd "$REPO/bench" && go build -o "$LG" ./cmd/loadgen) || exit 1

psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit_lg WITH (FORCE)" \
  -c "CREATE DATABASE conduit_lg TEMPLATE $TEMPLATE STRATEGY FILE_COPY" || exit 1

cd "$APP"
export DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg JWT_SECRET=dev-secret HOST=127.0.0.1 \
  PORT DB_POOL_SIZE=${DB_POOL_SIZE:-$(( 10 * $(nproc) > 90 ? 90 : 10 * $(nproc) ))} LANG=C.UTF-8 MIX_ENV=prod
elixir --sname conduitprof --cookie conduitprof -S mix run --no-halt > "$OUT/profile-server.log" 2>&1 &
server=$!
for _ in $(seq 240); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.5; done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" || { echo "server did not start; see $OUT/profile-server.log"; kill $server; exit 1; }

"$LG" run -target "http://127.0.0.1:$PORT" -users "$USERS" -ramp 5s -measure 40s -tail 2s -secret dev-secret \
  -articles "$ARTICLES" -think-scale 0.2 -run-id "p$(date +%s%N)" -q -out "$OUT/profile-load.json" > /dev/null 2>&1 &
load=$!
sleep 12
OUT="$OUT" elixir --sname conduitprobe --cookie conduitprof "$HERE/prof.exs"
wait $load
kill $server; sleep 1
echo "== top modules"; head -25 "$OUT/profile-mods.txt"
