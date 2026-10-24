#!/usr/bin/env bash
# Runs a set of configurations as interleaved A/B cycles: every config once in order, then again in reverse, for
# ROUNDS pairs of cycles. Slow drift on the host then affects every config about equally, which single runs per
# config don't survive (identical runs drifted by 4-10% over a batch on the first host).
#
#   [ROUNDS=1] tuning/interleave.sh <configs-file> <users>
#
# Each non-comment line of <configs-file> is `name: VAR=value VAR=value ...`, the environment for that config.
# Set APP=<variant dir> in a line to benchmark a build from make-variant.sh. Values are shell words, so quote one
# that holds spaces (ERL_AFLAGS="+sbwt none +S 6"). Example:
#
#   gc1:        APP=/srv/v/switches
#   gc5:        APP=/srv/v/switches XGC_EVERY=5
#   tags:       APP=/srv/v/tags
#
# Results append to $OUT/results.txt as `<prefix><name>-<run>`; summarize with tuning/summarize.py.
set -u
file=${1:?usage: interleave.sh <configs-file> <users>} users=${2:?usage: interleave.sh <configs-file> <users>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROUNDS=${ROUNDS:-1} PREFIX=${PREFIX:-ab-}
mapfile -t lines < <(grep -v '^\s*\(#\|$\)' "$file")
names=() envs=()
for l in "${lines[@]}"; do names+=("${l%%:*}"); envs+=("${l#*:}"); done

run=0
one() { run=$((run + 1)); echo "== $(date +%T) ${names[$1]} (run $2)"
        eval "env ${envs[$1]}" bash "\"$HERE/bench.sh\"" "\"$PREFIX${names[$1]}-$2\"" "$users"; }
for (( r=1; r<=ROUNDS; r++ )); do
  for (( i=0; i<${#names[@]}; i++ )); do one $i $((2*r-1)); done
  for (( i=${#names[@]}-1; i>=0; i-- )); do one $i $((2*r)); done
done
