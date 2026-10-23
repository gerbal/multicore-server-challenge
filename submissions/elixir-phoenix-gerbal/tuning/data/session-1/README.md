# Session 1 results (4-vCPU VM, everything on one machine)

All runs on a 4-vCPU, 15 GB VM shared by the app, Postgres 16 (default config) and the load generator, against the
dev seed, at `-think-scale 0.2`, with no Nginx. See `../../HANDOVER.md` for the method and how far to trust them.

`results.txt` has one line per `bench.sh` run (label, users, req/s, latency, errors, CPU per request). Each
`<label>-<users>.txt` is the loadgen's own summary for that run, with per-endpoint latencies and error breakdowns.

| Files | Batch | Notes |
|---|---|---|
| `300.txt` … `4000.txt`, `ladder-cpu.txt` | The first load test | One server process for the whole ladder, 10 s between steps. **Dirty**: later steps inherit earlier overload and writes. Superseded |
| `baseline*`, `no-compress`, `json-stdlib`, `pool-10`, `pool-20`, `no-busy-wait` (1000 users) | 1: single dials | One run each. Built with a switch that set `queue_interval` to 1,000 ms instead of the 2,000 ms default |
| `p10-qt50` … `p40-qt500` (1700 users) | 2: pool × queue target | One run each, compression off and schedulers sleeping. Order effects make it unreliable |
| `ab-*` (1700 users) | 3: interleaved | Forward then reversed cycle; average the `-1` and `-2` runs (`summarize.py results.txt ab-`) |
| `d4-*` (1700 users) | 4: interleaved, direct-mode tree | Same method; `summarize.py results.txt d4-` |
| `profile-mods.txt`, `profile-funs.txt` | Profile | `tprof` call time at 500 users, untuned build with compression on |
