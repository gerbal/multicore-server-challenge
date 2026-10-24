"""Compares configurations by the end of their runs, where a hold is decided, rather than by the whole window.

    python3 tuning/late.py <results-dir> <label-prefix> [last-seconds, default 60]

For each loadgen result `<prefix><name>-<run>-<users>.json` in <results-dir>: throughput and the median and worst
per-second p95 and p99 over the last seconds of the measured window, grouped by <name> with the runs side by side,
then the whole window's CPU per request from bench.sh's line in results.txt.
"""
import collections
import glob
import json
import os
import re
import statistics
import sys

directory, prefix = sys.argv[1], sys.argv[2]
last = int(sys.argv[3]) if len(sys.argv) > 3 else 60

cpu = {}
for line in open(os.path.join(directory, "results.txt")):
    m = re.match(r"(\S+)\s.*app_ms/req=([\d.]+) pg_ms/req=([\d.]+)", line)
    if m:
        cpu[m[1]] = (float(m[2]), float(m[3]))

runs = collections.defaultdict(list)
for path in sorted(glob.glob(os.path.join(directory, f"{prefix}*.json"))):
    label = re.sub(r"-\d+\.json$", "", os.path.basename(path))
    name = re.sub(r"-\d+$", "", label[len(prefix):])
    d = json.load(open(path))
    meta = d["meta"]
    end = (meta["window_end_ms"] - meta["start_at_ms"]) / 1000
    secs = [s for s in d["timeline"] if end - last <= s["t"] < end]
    runs[name].append({
        "rps": sum(s["completed"] for s in secs) / len(secs),
        "p95": statistics.median(s["p95_ms"] for s in secs), "p95max": max(s["p95_ms"] for s in secs),
        "p99": statistics.median(s["p99_ms"] for s in secs), "cpu": cpu.get(label, (0, 0)),
    })

print(f"last {last} s of the window   req/s   p95 med/max    p99 med   app_ms  pg_ms   runs (req/s; p95 med)")
for name, rs in sorted(runs.items()):
    mean = lambda k: sum(r[k] for r in rs) / len(rs)
    app = sum(r["cpu"][0] for r in rs) / len(rs)
    pg = sum(r["cpu"][1] for r in rs) / len(rs)
    print(f"{name:<26} {mean('rps'):7.0f} {mean('p95'):6.0f}/{mean('p95max'):<5.0f} {mean('p99'):9.0f} {app:8.3f} {pg:6.3f}   "
          + ", ".join(f"{r['rps']:.0f}; {r['p95']:.0f}" for r in rs))
