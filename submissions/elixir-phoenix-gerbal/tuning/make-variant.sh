#!/usr/bin/env bash
# Builds a variant of this submission in a scratch directory, so experiments never touch the committed tree and
# two variants can be benchmarked back to back without rebuilding.
#
#   tuning/make-variant.sh <dest-dir> [patch ...]
#
# Copies the submission (without _build, deps or tuning/) to <dest-dir>, applies each patch from tuning/patches/
# (by file name, e.g. experiment-switches.patch inline-tag-names.patch) with `patch -p1`, then runs build.sh there.
# Benchmark it with `APP=<dest-dir> tuning/bench.sh ...`.
set -euo pipefail
dest=${1:?usage: make-variant.sh <dest-dir> [patch ...]}; shift
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/.." && pwd)

rm -rf "$dest" && mkdir -p "$dest"
(cd "$APP" && tar --exclude=./_build --exclude=./deps --exclude=./tuning -cf - .) | tar -xf - -C "$dest"
for p in "$@"; do
  echo "== applying $p"
  (cd "$dest" && patch -p1 --forward < "$HERE/patches/$p")
done
echo "== building $dest"
bash "$dest/build.sh" > "$dest/build.log" 2>&1 || { echo "build failed; see $dest/build.log"; exit 1; }
echo "built: $dest/_build/prod/rel/conduit"
