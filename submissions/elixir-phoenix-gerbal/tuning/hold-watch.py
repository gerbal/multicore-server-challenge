"""Joins hold-watch.sh's samples with the loadgen's per-second timeline, in rows of WINDOW seconds.

    python3 tuning/hold-watch.py <run>.json <run>.watch.csv [window-seconds, default 30]

Per row: throughput and worst p95 (loadgen), BEAM and Postgres CPU per request (ticks over the row's completed
requests), BEAM RSS, then per hot table its dead rows, live-row growth since the start and autovacuum runs, and
checkpoints so far.
"""
import collections
import csv
import json
import os
import sys

HZ = os.sysconf("SC_CLK_TCK")
run = json.load(open(sys.argv[1]))
window = int(sys.argv[3]) if len(sys.argv) > 3 else 30
start = run["meta"]["start_at_ms"]
completed = {start + s["t"] * 1000: s for s in run["timeline"]}

samples = collections.defaultdict(dict)
for row in csv.DictReader(open(sys.argv[2])):
    samples[int(row["ms"])][row["table"]] = row
times = sorted(samples)
tables = ["articles", "article_tags", "favorites", "comments"]
first = samples[times[0]]


def requests_between(a, b):
    secs = [s for ms, s in completed.items() if a <= ms < b]
    return sum(s["completed"] for s in secs), max((s["p95_ms"] for s in secs), default=0)


print(f"{'t':>4} {'req/s':>6} {'p95':>5} {'app_ms':>7} {'pg_ms':>6} {'rss_mb':>6}  "
      + "  ".join(f"{t[:9]:>9} dead/+live/av" for t in tables) + "  ckpt")
prev = times[0]
for ms in times[1:]:
    if ms - prev < window * 1000 and ms != times[-1]:
        continue
    a, b = samples[prev]["articles"], samples[ms]["articles"]
    n, p95 = requests_between(prev, ms)
    if n:
        app = (int(b["beam_ticks"]) - int(a["beam_ticks"])) * 1000 / HZ / n
        pg = (int(b["pg_ticks"]) - int(a["pg_ticks"])) * 1000 / HZ / n
        cols = []
        for t in tables:
            r = samples[ms].get(t)
            cols.append(f"{int(r['dead']):>9}/+{int(r['live']) - int(first[t]['live'])}/{r['autovacuums']}" if r else "-")
        print(f"{(ms - start) / 1000:4.0f} {n * 1000 / (ms - prev):6.0f} {p95:5.0f} {app:7.3f} {pg:6.3f}"
              f" {int(b['beam_rss_kb']) / 1024:6.0f}  " + "  ".join(f"{c:>22}" for c in cols) + f"  {b['checkpoints']}")
    prev = ms
