# Handover: tuning `elixir-phoenix-gerbal`

This is for the Claude session that picks the work up on a bigger host. It covers where the submission stands,
what was measured and how far to trust it, the tools in this folder, the traps hit along the way, and what to do
next.

## The goal

The user asked for an idiomatic Elixir baseline for the challenge (Phoenix + Ecto, written the way a Phoenix team
would write it), and then to find the runtime **dials** that get the most out of that idiomatic code. The code stays
idiomatic: contexts, schemas, changesets, composable Ecto queries, JSON views. Tuning means configuration, VM
flags, library options, and small query changes a Phoenix developer would accept, not a rewrite into raw SQL or a
custom HTTP server (the repo already has `elixir-raw-foovoo` for that).

The user also chose **`Front: direct`**: most Phoenix deployments serve the internet from Bandit with no Nginx in
front, so this submission does too.

## Where things stand

- Branch `ccr-a5aea6fa-zl4011`, draft **PR #1** on `gerbal/multicore-server-challenge`. All work is committed and
  pushed. GitHub CI hadn't reported on the PR by the end of this session; check it first.
- Conformance: 197/197 on the dev seed (local Postgres 16; CI uses 18). `mix test`: 67 tests. `install.sh` and
  `build.sh` validated on a clean Ubuntu 24.04 container.
- Commits on the branch, oldest first:

| Commit | What |
|---|---|
| `5aa5c25` | First version: Phoenix + Ecto running SPEC.md's SQL strings verbatim through `Repo.query` |
| `d002c9a` | The idiomatic rewrite: contexts, schemas, changesets, Ecto queries, JSON views, 66 tests |
| `92fbd4d` | `install.sh` prints its version check in a UTF-8 locale |
| `35c48a4` | Bandit response compression off |
| `064f815` | `Front: direct`: `+Q 1000000`, backlog 8,192, GC after every keep-alive request, README |
| `3578003` | This `tuning/` folder (draft handover) |
| *(latest)* | Tag names aggregated inside the article query; handover finished; session 1 results |

### What the shipped config sets, and why

| Setting | Where | Evidence |
|---|---|---|
| Compression off | `runtime.exs` | Strong: two interleaved runs each at 1,700 users, 1,816 → 2,026 req/s, p95 317 → 193 ms, errors 1.14% → 0% |
| `+Q 1000000` | `start.sh` | Required: each user's socket is a port; the default 65,536 caps users. Verified the release boots with a 1,048,576 port limit |
| Listen backlog 8,192 | `runtime.exs` | Cheap headroom for direct connection bursts; the box's `somaxconn` is 65,535. Not load-tested |
| GC after every keep-alive request | `runtime.exs` | Memory: 80 → 14 KB per idle connection (15,000 idle connections). CPU cost: see batch 4 below |
| `read_timeout` 75 s | `runtime.exs` | Longer than the workload's 70 s maximum think time, so the server never closes a thinking user |
| Pool 10 per core, capped at 90 | `start.sh` | Matches the Go example. Locally 40 beat 20 and 10 at saturation (below); unconfirmed on 8 cores |
| Tag names in the article query | `Conduit.Blog` | Strong: see batch 4. One round trip and Ecto's preloader removed per article list/page |

## What was measured, and how far to trust it

**Host**: a 4-vCPU, 15 GB cloud VM. The app, Postgres 16 (default config, 128 MB `shared_buffers`) and the load
generator all shared the 4 cores, the dev seed (10k articles), `-think-scale 0.2` (each user makes about 5× a real
user's requests), no Nginx (so every run was effectively direct). The loadgen flagged every run at 1,000+ users
"LG-limited" because the whole box was above 75% CPU. **None of this is comparable to the leaderboard**; it ranks
settings against each other on this host, nothing more.

**Method**: `tuning/bench.sh` gives each run a fresh server and a fresh copy of the seed, a 300-user warm-up, then
15 s ramp + 30 s measured, and samples BEAM and Postgres CPU per request over exactly the measured window.
Configurations are compared with `tuning/interleave.sh`: one cycle through every config, then the same cycle
reversed, and the two runs averaged.

**Why interleaving matters**: three identical baselines run across one batch drifted by about 4% in app CPU per
request and 10% in Postgres CPU per request, and settings run in sequence improved roughly in run order. Single
runs per setting led me to conclusions I later had to retract (that a pool of 10 beat 40, and that two dials
together moved the untuned server from failing to passing). Only trust interleaved averages.

### Results that held up (averages of interleaved pairs, 1,700 users)

Batch 3, before `Front: direct` (pool 40 unless stated, queue target 50 ms, interval 2,000 ms):

| Config | req/s | p95 | p99 | Errors | App CPU/req | PG CPU/req |
|---|---:|---:|---:|---:|---:|---:|
| untuned | 1,816 | 317 ms | 424 ms | 1.14% ✗ | 1.17 ms | 0.78 ms |
| idle schedulers sleep (`+sbwt none` …) only | 1,836 | 316 ms | 374 ms | 2.69% ✗ | 1.18 ms | 0.76 ms |
| compression off only | 2,026 | 193 ms | 268 ms | 0% | 0.99 ms | 0.77 ms |
| compression off + schedulers sleep | 2,028 | 182 ms | 238 ms | 0% | 0.98 ms | 0.77 ms |
| … with pool 20 | 2,002 | 199 ms | 254 ms | 0% | 1.01 ms | 0.73 ms |
| … with pool 10 | 1,921 | 256 ms | 337 ms | 0.26% | 1.07 ms | 0.71 ms |

✗ fails the challenge's 1% error limit. Reading: compression off is the one clear win; busy-wait off adds nothing
measurable here (not shipped; worth one more look on 8 cores, where Postgres also shares the cores); smaller pools
cost less Postgres CPU per request but are slower at saturation.

Batch 4, on the direct-mode tree (`gc1` = GC after every request, as shipped):

| Config | req/s | p95 | p99 | Errors | App CPU/req | PG CPU/req | Runs (req/s) |
|---|---:|---:|---:|---:|---:|---:|---|
| `gc1` (the direct-mode tree before the tag change) | 1,984 | 220 ms | 295 ms | 0% | 1.008 ms | 0.781 ms | 1,946 / 2,021 |
| GC every 5th request (Bandit's default) | 2,026 | 201 ms | 268 ms | 0% | 1.007 ms | 0.771 ms | 2,000 / 2,051 |
| Ecto + Phoenix logging off | 2,012 | 193 ms | 232 ms | 0% | 0.989 ms | 0.786 ms | 2,000 / 2,023 |
| `pool_count: 2`, `pool_size: 20` | 1,954 | 270 ms | 361 ms | 0.35% | 1.038 ms | 0.802 ms | 2,000 / 1,908 |
| **tag names in the article query** | **2,131** | **114 ms** | **164 ms** | **0%** | **0.920 ms** | **0.724 ms** | 2,156 / 2,107 |

Reading:
- **Tag names in the query: shipped.** +7% req/s, p95 halved, 9% less app and 7% less Postgres CPU per request,
  and both runs beat every run of every other config.
- **GC every request vs every 5th:** identical CPU per request and overlapping runs; the 5.7x idle-memory saving
  is certain, so every request stays. Recheck latency on the new host.
- **Logging off:** about 2% less app CPU per request, but runs overlap with `gc1`. Likely a win; confirm first.
- **Two pools:** worse, and the only config that shed requests in both runs (Ecto routes to a random pool). Out.

### Single-run or 1,000-user observations (weaker)

- Elixir's built-in `JSON` instead of Jason: no change in CPU per request (1,000 users, one run). I never confirmed
  Phoenix actually used it in that run.
- Queue target 500 ms vs 50 ms: no consistent effect once compression was off; with it on, a high target trades
  errors for latency. Not interleaved.
- Profile (`tprof` call time, 500 users, before the tuning): Jason encoding ~10%, socket writes (`port_command`)
  ~12%, Ecto planner + its ETS cache ~10%, gzip ~4%, the rest spread thin. Nothing pathological.

## Open questions, in the order I'd tackle them

1. **Find the shipped build's knee on the new host** (full seed, `TEMPLATE=conduit_seed`, loadgen on another machine
   if possible), then re-run the batch-4 comparisons there (logging, GC interval, pool size) with `interleave.sh`.
   Compression and the tag change are already in the tree; reverting either is a one-line or small patch if you want
   to confirm them at that scale.
2. **Logging off** (Ecto `log: false`, `config :phoenix, :logger, false`): batch 4 above. If it holds on the new
   host, ship it; it's a standard production setting.
3. **GC every request vs every 5th**: the memory saving is certain; check the latency/CPU cost on the new host. A
   middle value (2 or 3) is an option.
4. **Pool size on 8 cores** (Postgres gets 8 cores there, minus the app): sweep 10/20/40/80 interleaved.
5. **Real direct-mode scale**: `THINK_SCALE=1` with tens of thousands of users (raise `ulimit -n`; the box gives
   200,000). Check memory (14 KB/idle connection measured here), accept behaviour and the backlog under the ramp.
6. **`jit: "off"` via Postgrex `parameters:`** on the box's tuned Postgres (`box/pg-conf.sh`); `elixir-raw-foovoo`
   sets it. Meaningless on this host's default-config Postgres.
7. Lists load `articles.body` and authors load `password_hash`/`email` that the JSON never sends. Selecting only the
   needed fields is a small idiomatic change worth measuring.
8. `+sbwt none` and scheduler counts (`+S`) once Postgres and the app compete for 8 real cores.

## Setting up the new host

To get close to the benchmark box (8 vCPU, 16 GB, Ubuntu 24.04, Postgres 18):

1. `box/setup-box.sh` documents the box (kernel limits, sysctl, Postgres config via `box/pg-conf.sh`). Apply the
   same Postgres config and file limits; the defaults this session ran with (128 MB `shared_buffers`, 20,000 open
   files) are far from the box.
2. Go >= 1.27, `psql`, `curl`, `bc`, `python3`; then `bash seed/make-seed.sh` for the full seed (`conduit_seed`) and
   `bash seed/make-seed.sh --dev` for the quick one.
3. `sudo bash submissions/elixir-phoenix-gerbal/install.sh` (Erlang/OTP + Elixir), `bash .../build.sh`, and
   `bash test/run.sh submissions/elixir-phoenix-gerbal` to confirm 197/197 before measuring anything.
4. Put the load generator on another machine if you can: on one machine it competes with the app and Postgres, and
   the loadgen marks such runs "LG-limited". `bench.sh` assumes everything is local; for a remote loadgen, run
   `bench/cmd/loadgen run -target http://<host>:<port> ...` there and keep the per-run fresh DB + restart.

## Tools in this folder

| File | What it does |
|---|---|
| `bench.sh` | One measured point: fresh DB + server, warm-up, run, CPU per request. All settings via env (see its header) |
| `interleave.sh` | Runs a configs file as forward + reversed cycles through `bench.sh` |
| `summarize.py` | Averages result lines per config, with the per-run spread |
| `make-variant.sh` | Copies the submission to a scratch dir, applies patches, builds it, so variants never touch the tree |
| `patches/experiment-switches.patch` | Env switches for experiments: `XPOOL_COUNT`, `XQ_TARGET`, `XQ_INTERVAL`, `XREPO_LOG`, `XPHX_LOG`, `XGC_EVERY`. Never commit it applied |
| `profile.sh` + `prof.exs` | `tprof` call-time profile of the prod build under load |
| `idle-memory.sh` + `idle_conns.py` | Memory per idle keep-alive connection |
| `port80.sh` | Binds port 80 as an unprivileged user with only the ambient capability, like `box/challenge.service` |
| `data/session-1/` | Every result line and loadgen summary from this session (`results.txt` is the index) |

Example on the new host:

```bash
cd submissions/elixir-phoenix-gerbal
bash build.sh
tuning/make-variant.sh /srv/v/switches experiment-switches.patch
cat > /tmp/configs <<'EOF'
shipped:   APP=/srv/v/switches
gc5:       APP=/srv/v/switches XGC_EVERY=5
nolog:     APP=/srv/v/switches XREPO_LOG=false XPHX_LOG=false
pool20:    APP=/srv/v/switches DB_POOL_SIZE=20
EOF
TEMPLATE=conduit_seed THINK_SCALE=0.2 OUT=/srv/results tuning/interleave.sh /tmp/configs 4000
python3 tuning/summarize.py /srv/results/results.txt ab-
```

## Traps I hit (so you don't)

- **Never give the loadgen `-out /dev/null`.** It writes results with a rename (`bench/cmd/loadgen/run.go`), and as
  root that replaced the `/dev/null` device with a regular file, which broke later tests in confusing ways
  (`cannot create /dev/null: Permission denied`). Fix: `rm /dev/null && mknod -m 666 /dev/null c 1 3`.
- **`pkill -f <pattern>` can kill your own tool call.** The tool's wrapper shell carries the whole command text,
  heredocs included, so a pattern that appears anywhere in the command matches the wrapper (exit code 144). Put
  kill logic in script files and run them, or use the `[x]yz` regex trick, and never write a heredoc containing a
  pattern you pkill in the same command.
- **The first host's Postgres stopped on container restarts.** Check it's up before a batch
  (`pg_ctlcluster 16 main start` there).
- **A load-test ladder on one long-running server is a dirty measurement.** Steps that overloaded the server and
  accumulated writes made a later 1,700-user step fail with 16.7% errors that a clean run didn't reproduce. Fresh
  server and DB per run (`bench.sh` does this).
- **`:tprof` isn't in the release, and Mix prunes it from `mix run`'s code path.** `prof.exs` adds OTP's tools
  `ebin` to the remote node's path.
- **Docker Hub rate-limited image pulls** (429). `mirror.gcr.io/library/ubuntu:24.04` is the same official image.
- **DBConnection's `queue_interval` default is 2,000 ms.** My first experiment switch defaulted it to 1,000 ms by
  mistake, so batch 1 ran with a non-default interval. Read option defaults from `deps/`, not from memory.
- Ecto gotchas already handled in the code: Joken validates only the claims a token carries (so `exp` presence is
  checked explicitly); `cast` drops `""` and `nil` from string arrays unless `empty_values: []`; Ecto's `:integer`
  accepts `"+5"` (hence `Conduit.Types.PlainInteger`).

## Working conventions on this branch

- Experiments run in scratch copies (`make-variant.sh`); the committed tree only gets settings that won an
  interleaved comparison, with the evidence in the README or commit message.
- Before pushing: `mix format --check-formatted`, `mix test`, `bash test/run.sh submissions/elixir-phoenix-gerbal`.
- Commits end with the session's attribution lines; the PR stays a draft until the user says otherwise.
- `tuning/` is a working folder for this effort; ask the user whether to keep it in the submission before the PR is
  marked ready.
