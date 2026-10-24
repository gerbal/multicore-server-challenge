#!/usr/bin/env bash
# The scoring search's shape on this rig, from a starting guess instead of doubling from 500 users: 2-minute probes
# (60 s ramp + 60 s measured) stepping up 10% from <start> until one fails (or down 10% until one passes), bisect to
# 5%, then 5-minute holds (60 s + 300 s) from the highest passing probe, stepping down 5% until one passes = score.
# User counts are rounded like `loadgen search` (two significant digits), and a run passes with p95 < 500 ms,
# p99 < 1 s and < 1% errors (LEADERBOARD.md).
#
#   [ENV=...] tuning/search.sh <label> <start-users>
#
# Every run goes through bench.sh, so its settings (APP, OUT, TEMPLATE, THINK_SCALE=1 for real pacing, APP_CPUS,
# LG_CPUS, ...) apply. RAMP, MEASURE and TAIL are set here.
set -uo pipefail
label=${1:?usage: search.sh <label> <start-users>} start=${2:?usage: search.sh <label> <start-users>}
HERE=$(cd "$(dirname "$0")" && pwd)

round() { python3 -c "import math; x=$1; s=max(10**(math.floor(math.log10(x))-1), 10); print(int(round(x/s)*s))"; }

# run <phase> <users> <measure-seconds>: prints the bench.sh line and returns 0 when the run passes.
run() {
  local line
  line=$(RAMP=60 MEASURE=$3 TAIL=15 bash "$HERE/bench.sh" "$label-$1-$2" "$2" | tail -1)
  echo "$line"
  python3 - "$line" <<'EOF'
import re, sys
m = dict(re.findall(r"(p95|p99|err%)=([\d.]+)", sys.argv[1]))
sys.exit(0 if m and float(m["p95"]) < 500 and float(m["p99"]) < 1000 and float(m["err%"]) < 1 else 1)
EOF
}

lo="" hi=""
u=$start
if run probe "$u" 60; then
  lo=$u
  while u=$(round "$((u * 11 / 10))") && run probe "$u" 60; do lo=$u; done
  hi=$u
else
  hi=$u
  while u=$(round "$((u * 9 / 10))") && ! run probe "$u" 60; do hi=$u; done
  lo=$u
fi
while [ $((hi - lo)) -gt $((lo / 20)) ]; do
  m=$(round "$(((lo + hi) / 2))")
  { [ "$m" -le "$lo" ] || [ "$m" -ge "$hi" ]; } && break
  if run probe "$m" 60; then lo=$m; else hi=$m; fi
done
echo "== probes: highest pass $lo, lowest fail $hi"

u=$lo
until run hold "$u" 300; do u=$(round "$((u * 95 / 100))"); done
echo "== RESULT: score $u users (5-minute hold passed)"
