#!/usr/bin/env bash
# One bench.sh run (a 5-minute hold by default) with a sampler every SAMPLE_EVERY seconds, to see what changes while
# a long run degrades: BEAM and Postgres CPU ticks, BEAM RSS, and per hot table the live and dead rows, autovacuum
# runs and heap/index block reads, plus checkpoints. hold-watch.py joins it with the loadgen's per-second timeline.
#
#   [ENV=...] tuning/hold-watch.sh <label> <users>
#
# bench.sh's settings apply (APP, OUT, TEMPLATE, THINK_SCALE, APP_CPUS, LG_CPUS); RAMP, MEASURE and TAIL default to
# a hold's 60, 300 and 15 s.
set -uo pipefail
label=${1:?usage: hold-watch.sh <label> <users>} users=${2:?usage: hold-watch.sh <label> <users>}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$PWD/tuning-results} SAMPLE_EVERY=${SAMPLE_EVERY:-5} APP=${APP:-$(cd "$HERE/.." && pwd)}
# The release's own command line: old runs' zombie beam.smp processes match `-x beam.smp` but have no command line.
server="$APP/_build/prod/rel/conduit/erts"
export RAMP=${RAMP:-60} MEASURE=${MEASURE:-300} TAIL=${TAIL:-15} OUT
mkdir -p "$OUT"
samples="$OUT/$label-$users.watch.csv"

ticks() { local t=0 s; for p in $(pgrep -f "$1"); do s=$(cut -d' ' -f14,15 /proc/$p/stat 2>/dev/null) && t=$((t + ${s% *} + ${s#* })); done; echo $t; }

sample() {
  echo "ms,beam_ticks,pg_ticks,beam_rss_kb,table,live,dead,autovacuums,heap_read,heap_hit,idx_hit,checkpoints" > "$samples"
  until pgrep -f "$server" > /dev/null; do sleep 0.5; done
  sleep 2
  while pgrep -f "$server" > /dev/null; do
    local ms beam pg rss
    ms=$(date +%s%3N) beam=$(ticks beam.smp) pg=$(ticks 'postgres: ')
    rss=$(awk '/^VmRSS/ {print $2}' /proc/"$(pgrep -n -f "$server.*beam.smp")"/status 2>/dev/null || echo 0)
    psql -X -qtA -F, -d conduit_lg -c "
      SELECT '$ms', '$beam', '$pg', '$rss', s.relname, s.n_live_tup, s.n_dead_tup, s.autovacuum_count,
             io.heap_blks_read, io.heap_blks_hit, io.idx_blks_hit, (SELECT num_timed + num_requested FROM pg_stat_checkpointer)
        FROM pg_stat_user_tables s JOIN pg_statio_user_tables io USING (relid)
       WHERE s.relname IN ('articles', 'article_tags', 'favorites', 'comments', 'follows', 'users')" >> "$samples" 2>/dev/null
    sleep "$SAMPLE_EVERY"
  done
}

sample &
sampler=$!
bash "$HERE/bench.sh" "$label" "$users"
wait "$sampler"
echo "samples: $samples"
