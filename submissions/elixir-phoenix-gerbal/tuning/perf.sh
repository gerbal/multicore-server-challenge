#!/usr/bin/env bash
# Samples the release with Linux perf during one bench.sh run: a flame graph, a flat profile and folded stacks of
# where the BEAM's CPU goes at full load, without tprof's tracing overhead.
#
#   [ENV=...] tuning/perf.sh <label> <users>        (run on the host, not inside the bench container)
#
# perf can't run inside the bench container: podman's default seccomp profile blocks perf_event_open. It runs in a
# helper container instead, which shares the bench container's PID namespace (and podman's rootless user namespace)
# with seccomp off for itself only. The host's kernel.perf_event_paranoid of 2 allows user-space samples of your own
# processes, so time in the kernel (the TCP stack) isn't sampled; the JIT's perf map names the Erlang functions.
#
# The helper image needs perf and js-d3-flame-graph: a Fedora toolbox with `dnf install perf js-d3-flame-graph`,
# saved with `podman commit <toolbox> localhost/perf-tools`.
#
# TARGET=postgres samples the benchmark database's Postgres backends instead of the BEAM (whose stacks are then just
# Postgres's C code; perf-layers.py's groups are the BEAM's, so read flat.txt and the flame graph).
#
# Settings (environment): BENCH (bench container, default mcsc-bench), PERF_IMAGE (default localhost/perf-tools),
# SAMPLE_SECONDS (default 20, inside the measured window), FREQ (samples/s per thread, default 499), RESULTS (host
# directory, default ./tuning-results/perf-<label>). Passed through to bench.sh: APP (a path inside the container),
# OUT TEMPLATE THINK_SCALE RAMP MEASURE TAIL APP_CPUS LG_CPUS DB_POOL_SIZE ERL_AFLAGS and the X* experiment switches.
set -euo pipefail
label=${1:?usage: perf.sh <label> <users>} users=${2:?usage: perf.sh <label> <users>}

BENCH=${BENCH:-mcsc-bench} PERF_IMAGE=${PERF_IMAGE:-localhost/perf-tools}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-20} FREQ=${FREQ:-499}
RESULTS=$(mkdir -p "${RESULTS:-$PWD/tuning-results/perf-$label}" && cd "${RESULTS:-$PWD/tuning-results/perf-$label}" && pwd)
SUB=/repo/submissions/elixir-phoenix-gerbal
APP=${APP:-$SUB} OUT=${OUT:-/srv/results/perf}
MEASURE=${MEASURE:-$((SAMPLE_SECONDS + 10))}

# The bench run, with the JIT writing /tmp/perf-<pid>.map and keeping frame pointers so stacks unwind.
env_args=(APP="$APP" OUT="$OUT" MEASURE="$MEASURE" ERL_AFLAGS="+JPperf true ${ERL_AFLAGS:-}")
for v in TEMPLATE THINK_SCALE RAMP TAIL APP_CPUS LG_CPUS DB_POOL_SIZE XQ_TARGET XPOOL_COUNT XQ_INTERVAL XREPO_LOG \
         XPHX_LOG XGC_EVERY XLOG_EXC XMIN_HEAP XPG_REF XPG_PLAN XSIGNER XTI_SOCKET; do
  [ -n "${!v:-}" ] && env_args+=("$v=${!v}")
done
podman exec "$BENCH" bash -c "mkdir -p '$OUT' && touch '$OUT/.perf-start'"
podman exec "$BENCH" env "${env_args[@]}" bash -c ". /root/env.sh; cd '$SUB'; tuning/bench.sh '$label' '$users'" \
  > "$RESULTS/bench.txt" 2>&1 &
bench=$!

# bench.sh writes .t0 as the measured window opens.
until podman exec "$BENCH" test "$OUT/.t0" -nt "$OUT/.perf-start"; do
  kill -0 "$bench" 2>/dev/null || { echo "bench.sh ended early:"; cat "$RESULTS/bench.txt"; exit 1; }
  sleep 1
done
pid=$(podman exec "$BENCH" pgrep -n -x beam.smp)
targets=$pid
if [ "${TARGET:-beam}" = postgres ]; then
  targets=$(podman exec "$BENCH" pgrep -d, -f 'postgres: .* conduit_lg ')
  echo "== sampling $(tr ',' '\n' <<< "$targets" | wc -l) Postgres backends for ${SAMPLE_SECONDS}s at ${FREQ} Hz"
else
  echo "== sampling beam.smp (pid $pid) for ${SAMPLE_SECONDS}s at ${FREQ} Hz"
fi

helper() {
  # SYS_PTRACE (namespaced, rootless) lets it attach to processes of other users there, like Postgres's backends.
  podman run --rm --pid="container:$BENCH" --security-opt seccomp=unconfined --security-opt label=disable --cap-add SYS_PTRACE \
    -v "$RESULTS:/out" "$PERF_IMAGE" bash -c "$1"
}
# Keep the perf map while the process exists; resolving later goes through the bench container's root.
helper "perf record -q -F $FREQ -g -p $targets -o /out/perf.data -- sleep $SAMPLE_SECONDS &&
        cp /proc/$pid/root/tmp/perf-$pid.map /out/" ||
  { echo "perf record failed; waiting for bench.sh, so that a rerun doesn't overlap it"; wait "$bench"; exit 1; }
wait "$bench" || true
cat "$RESULTS/bench.txt"

echo "== reports in $RESULTS"
# With the process gone, perf looks binaries up by their paths in its own filesystem, so the release and Ubuntu's
# libraries are linked there from the bench container's root (PID 1 there lives as long as the container).
helper "cd /out && cp perf-$pid.map /tmp/ &&
        mkdir -p \$(dirname '$APP') && ln -s '/proc/1/root$APP' '$APP' &&
        ln -s /proc/1/root/usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu &&
        ln -s /proc/1/root/usr/lib/postgresql /usr/lib/postgresql &&
        perf report -i perf.data --stdio --no-children --sort dso,symbol -g none --percent-limit 0.2 \
          > flat.txt 2> /dev/null &&
        perf script -i perf.data -F comm,tid,ip,sym > script.txt 2> /dev/null &&
        perf script -i perf.data -s /usr/libexec/perf-core/scripts/python/flamegraph.py -- -o flamegraph.html \
          > /dev/null 2>&1 || true"
[ "${TARGET:-beam}" = postgres ] || python3 "$(dirname "$0")/perf-layers.py" "$RESULTS/script.txt" | tee "$RESULTS/layers.txt"
