"""Averages bench.sh result lines per configuration.

    python3 tuning/summarize.py <results.txt> [label-prefix]

Groups lines whose label is `<name>-<run number>` by <name> (optionally only labels starting with the prefix) and
prints the mean of each metric with the per-run req/s, so the spread between runs is visible next to the mean.
"""
import collections
import re
import sys

path = sys.argv[1]
prefix = sys.argv[2] if len(sys.argv) > 2 else ""
metrics = ["req/s", "p95", "p99", "err%", "app_ms/req", "pg_ms/req"]
groups = collections.OrderedDict()

for line in open(path):
    if not line.startswith(prefix) or "req/s=" not in line:
        continue
    label = line.split()[0]
    name = re.sub(r"-\d+$", "", label)
    fields = dict(re.findall(r"(\S+?)=(\S+)", line))
    groups.setdefault((name, fields["users"]), []).append({m: float(fields[m].rstrip("%")) for m in metrics})

print(f"{'config':24} {'users':>6} {'n':>2} {'req/s':>8} {'p95':>7} {'p99':>7} {'err%':>6} {'app_ms':>7} {'pg_ms':>7}  runs (req/s)")
for (name, users), runs in groups.items():
    mean = {m: sum(r[m] for r in runs) / len(runs) for m in metrics}
    print(f"{name:24} {users:>6} {len(runs):>2} {mean['req/s']:8.0f} {mean['p95']:7.0f} {mean['p99']:7.0f} "
          f"{mean['err%']:6.2f} {mean['app_ms/req']:7.3f} {mean['pg_ms/req']:7.3f}  {[round(r['req/s']) for r in runs]}")
