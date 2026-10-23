#!/usr/bin/env bash
# Memory per idle keep-alive connection, the main cost of Front: direct (one connection per user, mostly idle).
#
#   tuning/idle-memory.sh [connections=15000] [hold_seconds=40]
#
# Starts the release, records BEAM RSS, opens N connections that each make one request and then sit idle (like a
# user between pages), and records RSS again. Keep hold_seconds under the server's 75 s read_timeout, or the
# server closes them (correctly) before the end. Needs a file limit above N for both processes.
set -u
N=${1:-15000} HOLD=${2:-40}
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${APP:-$(cd "$HERE/.." && pwd)}
OUT=${OUT:-$PWD/tuning-results} TEMPLATE=${TEMPLATE:-conduit_dev} PORT=${PORT:-3120}
export PGHOST=${PGHOST:-127.0.0.1} PGUSER=${PGUSER:-postgres}
mkdir -p "$OUT"
ulimit -n $(( N + 5000 )) 2>/dev/null || { echo "need a file limit of at least $(( N + 5000 )) (ulimit -Hn is $(ulimit -Hn))"; exit 1; }

psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit_idle WITH (FORCE)" \
  -c "CREATE DATABASE conduit_idle TEMPLATE $TEMPLATE STRATEGY FILE_COPY" || exit 1
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_idle JWT_SECRET=x HOST=127.0.0.1 PORT=$PORT \
  bash "$APP/start.sh" > "$OUT/idle-server.log" 2>&1 &
for _ in $(seq 120); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.5; done
pid=$(pgrep -f "$APP/_build/prod/rel/conduit/erts" | head -1)
rss() { echo $(( $(awk '/VmRSS/ {print $2}' "/proc/$pid/status") / 1024 )); }
sleep 3; before=$(rss); echo "BEAM RSS before: ${before} MB"

python3 -I "$HERE/idle_conns.py" "$PORT" "$N" "$HOLD" > "$OUT/idle-client.log" 2>&1 &
client=$!
until grep -q HOLDING "$OUT/idle-client.log" 2>/dev/null || ! kill -0 $client 2>/dev/null; do sleep 1; done
head -1 "$OUT/idle-client.log"
sleep 10; held=$(rss)
echo "BEAM RSS holding $N idle connections: ${held} MB -> $(( (held - before) * 1024 / N )) KB per connection"
wait $client; tail -1 "$OUT/idle-client.log"
kill "$pid"; sleep 1
psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit_idle WITH (FORCE)"
