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
| `81ffe73` | Tag names aggregated inside the article query |
| `73caebb`, `33896c9` | Handover finished; session 1 data |
| `b4cdc35` | Select only the columns the JSON sends; `bench.sh` CPU pinning; session 2 data and this update |
| the next commit | Ecto `queue_target` 200 ms, from the real-pacing holds below |

### What the shipped config sets, and why

| Setting | Where | Evidence |
|---|---|---|
| Compression off | `runtime.exs` | Strong: two interleaved runs each at 1,700 users, 1,816 → 2,026 req/s, p95 317 → 193 ms, errors 1.14% → 0% |
| `+Q 1000000` | `start.sh` | Required: each user's socket is a port; the default 65,536 caps users. Verified the release boots with a 1,048,576 port limit |
| Listen backlog 8,192 | `runtime.exs` | Cheap headroom for direct connection bursts; the box's `somaxconn` is 65,535. Not load-tested |
| GC after every keep-alive request | `runtime.exs` | Memory: 80 → 14 KB per idle connection (15,000 idle connections). CPU cost: see batch 4 below |
| `read_timeout` 75 s | `runtime.exs` | Longer than the workload's 70 s maximum think time, so the server never closes a thinking user |
| Ecto `queue_target` 200 ms | `runtime.exs` | Strong at real pacing: batch 8 (session 2). The default sheds queries as 500s at saturation |
| Pool 10 per core, capped at 90 | `start.sh` | Matches the Go example. Locally 40 beat 20 and 10 at saturation (below); unconfirmed on 8 cores |
| Tag names in the article query | `Conduit.Blog` | Strong: see batch 4. One round trip and Ecto's preloader removed per article list/page |
| Only the columns the JSON sends | `Conduit.Blog` | Strong: batch 6 (session 2). Lists skip `body`, authors skip `email`/`password_hash` |

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

## Session 2: an 8-thread stand-in for the box, full seed

**Host**: a Ryzen 9 5900X workstation (12 cores / 24 threads, 125 GB, Fedora Atomic), with everything in a rootless
podman Ubuntu 24.04 container (setup below). The app and Postgres 18 (the box's pgtune config for 8 vCPU / 16 GB)
were pinned to CPUs 0-3,12-15, i.e. 4 cores / 8 threads on one CCD, so the BEAM ran 8 schedulers and `start.sh`
picked pool 80. The loadgen was pinned to the other CCD (6-11,18-23) and no run was LG-limited. Full seed,
`THINK_SCALE=0.2`. Closer to the box than session 1, but SMT threads on a desktop chip, not the box's vCPUs.

Knee of the shipped build (single runs, fresh server and DB each):

| Users | req/s | p95 | p99 | Errors | App cores | PG cores |
|---:|---:|---:|---:|---:|---:|---:|
| 2,000 | 2,634 | 2.8 ms | 4.6 ms | 0% | 2.93 | 1.26 |
| 3,500 | 4,636 | 4.4 ms | 7.0 ms | 0% | 4.39 | 2.39 |
| 5,000 | 6,588 | 26 ms | 44 ms | 0% | 3.77 | 3.74 |
| 6,500 | 7,008 | 238 ms | 1,159 ms | 3.29% ✗ | 3.78 | 3.79 |
| 8,000 | 8,149 | 519 ms | 664 ms | 55% ✗ | 5.23 | 2.36 |

From 5,000 users the 8 threads are saturated, split about evenly between the BEAM and Postgres, so only less CPU per
request moves the knee. (App CPU per request falls from ~0.95 to ~0.55 ms as load rises: batching at saturation.)

Batch 5, interleaved, `ROUNDS=2` (4 runs each), 6,000 users:

| Config | req/s | p95 | p99 | App CPU/req | PG CPU/req | Runs (req/s) |
|---|---:|---:|---:|---:|---:|---|
| shipped | 7,042 | 164 ms | 203 ms | 0.524 ms | 0.554 ms | 6,844 / 7,155 / 7,181 / 6,991 |
| GC every 5th request | 7,055 | 156 ms | 200 ms | 0.519 ms | 0.557 ms | 6,874 / 7,168 / 7,196 / 6,982 |
| Ecto + Phoenix logging off | 7,093 | 159 ms | 195 ms | 0.518 ms | 0.553 ms | 7,058 / 7,072 / 7,152 / 7,089 |
| pool 20 | 7,109 | 150 ms | 192 ms | 0.567 ms | 0.496 ms | 7,147 / 7,032 / 7,187 / 7,069 |

Reading: no dial wins. All four are within 1% while runs of one config spread 5%. GC every request costs nothing
measurable, so it stays (the memory saving is certain). Logging off saves ~1% app CPU, too small to resolve. Pool 20
moves CPU from Postgres to the BEAM (+8% / -10%) for the same total.

Batch 6, interleaved, `ROUNDS=2`, 6,000 users:

| Config | req/s | p95 | p99 | App CPU/req | PG CPU/req | Runs (req/s) |
|---|---:|---:|---:|---:|---:|---|
| shipped | 6,984 | 172 ms | 215 ms | 0.527 ms | 0.558 ms | 6,971 / 7,038 / 7,024 / 6,905 |
| **only the columns the JSON sends** | **7,174** | **142 ms** | **174 ms** | **0.514 ms** | **0.547 ms** | 7,154 / 7,204 / 7,188 / 7,151 |

**Shipped**: every run beat every run of the old query. `articles_query/2` takes a field list (lists pass the
summary fields without `body`; single articles add it) and selects `merge(struct(a, ^fields), %{...})`; authors of
articles and comments load `[:id, :username, :bio, :image]`.

**JIT (old question 6) is settled without a run**: JIT never fires. I logged every statement under load and ran
`EXPLAIN (GENERIC_PLAN)` on each: only the plain article list's generic plan (unknown `LIMIT`/`OFFSET`) costs more
than `jit_above_cost` (848k vs 100k), and the plan cache never picks it because the custom plans cost 31 (plain
list) to 382 (tag list) at the loadgen's offsets (0-40). `jit: "off"` would change nothing.

### Real pacing (`THINK_SCALE=1`), the search's probe and hold shapes

Probes are 60 s ramp + 60 s measured, holds 60 s ramp + 300 s measured, like `loadgen search`; tail 15 s. Peak BEAM
RSS and established connections were sampled every 2 s (`/srv/rss-watch.sh` in the container; not committed).

Knee of the build with the column change (single probe runs):

| Users | req/s | p95 | p99 | Errors | BEAM peak RSS | Peak connections |
|---:|---:|---:|---:|---:|---:|---:|
| 15,000 | 3,974 | 3.7 ms | 6.0 ms | 0% | 555 MB | 15,000 |
| 22,000 | 5,830 | 7.2 ms | 12 ms | 0% | 694 MB | 22,000 |
| 26,000 | 6,856 | 36 ms | 73 ms | 0% | 812 MB | 26,000 |
| 30,000 | 7,580 | 261 ms | 346 ms | 30% ✗ | 1,168 MB | 25,996 |

Same ~7,000 req/s ceiling as at `THINK_SCALE=0.2`: real pacing adds no new bottleneck. Each user costs ~23 KB
(far below the box's 16 GB), every user got its own connection, and nothing was LG-limited. The 30k failure is all
HTTP 500s from DBConnection shedding queries that waited past the 50 ms `queue_target`; each 500 also cost the
user its connection (188,065 TCP connects for 30,000 users).

Batch 7, probes at 28,000 users, interleaved, 2 runs each:

| Config | req/s | p95 | p99 | Errors |
|---|---:|---:|---:|---:|
| shipped (`queue_target` 50 ms) | 7,130 | 232 ms | 324 ms | 5.28% ✗ (6.95 / 3.61) |
| `queue_target` 200 ms | 7,068 | 349 ms | 435 ms | 0% |
| `queue_target` 500 ms | 7,033 | 384 ms | 472 ms | 0% |

The probe win doesn't survive a hold at 28k: 200 ms failed a 300 s hold there on latency (p95 535 ms, 0% errors),
while shipped passed a 300 s hold at 26k (p95 66 ms). So batch 8 compared holds at 27,000 users:

| Config (300 s holds) | req/s | p95 | p99 | Errors | Verdicts |
|---|---:|---:|---:|---:|---|
| shipped | 6,914 | 224 ms | 312 ms | 3.05% | FAIL (1.50%), FAIL (4.60%) |
| **`queue_target` 200 ms** | **6,765** | **409 ms** | **526 ms** | **0%** | **PASS, PASS** |

**Shipped**: the highest passing hold moves from 26k to 27k (+4%, inside the search's 5% resolution but the same in
both runs). It only changes behaviour when the pool is saturated. 500 ms was not held-tested; it would have less
latency headroom.

## Open questions, in the order I'd tackle them

After session 2 (questions 1-7 below are done or settled; see above):

- **The overload cliff.** From 26k to 30k users errors go 0% → 30%, and every 500 closes the user's connection,
  so the load turns into a reconnect storm. Prod logs at `:warning`, so each shed query also writes a ~20-line
  error with a stack trace (6,743 of them at 30k): cost of logging under overload is worth measuring.
- **CPU per request is what's left.** Profile at saturation on the 8-thread setup (`profile.sh`) before guessing.
  Candidates: the per-article correlated subqueries (favorite count, `favorited`, `following`) vs one aggregate
  join, and `GET /api/articles/:slug/comments` (the most frequent request with the article lookup) as one query
  instead of two.
- Logging off once more with `ROUNDS=3` if a 1% win is worth shipping; it's a standard production setting either way.
- `+sbwt none` and `+S` on the 8-thread setup (old question 8).

Original list from session 1:

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

## Setting up the session-2 host again (podman on the workstation)

The container is `mcsc-bench` (image `mirror.gcr.io/library/ubuntu:24.04`, the repo mounted at `/repo`):

```bash
podman run -d --name mcsc-bench -v "$PWD":/repo:Z --workdir /repo --ulimit nofile=1048576:1048576 --shm-size=4g \
  --sysctl net.core.somaxconn=65535 --sysctl net.ipv4.tcp_max_syn_backlog=65535 \
  --sysctl net.ipv4.ip_local_port_range="1024 65535" --sysctl net.ipv4.tcp_tw_reuse=1 \
  mirror.gcr.io/library/ubuntu:24.04 sleep infinity
```

Inside it: PGDG `postgresql-18`, Go 1.27.1 in `/usr/local/go`, `install.sh`; Postgres configured as
`box/setup-box.sh` does, with `box/pg-conf.sh` computed for 16 GB (its `MEM_KB` line replaced) under
`taskset -c 0-3,12-15`, and started with `taskset -c 0-3,12-15 pg_ctlcluster 18 main start` so every backend
inherits the pinning. `/root/env.sh` sets `PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres` and the PATH.
A batch: `podman exec mcsc-bench bash -c '. /root/env.sh; cd /repo/submissions/elixir-phoenix-gerbal;
APP_CPUS=0-3,12-15 LG_CPUS=6-11,18-23 TEMPLATE=conduit_seed OUT=... tuning/interleave.sh ...'`.

Traps on this host:
- **Container DNS hung** (pasta's forwarder vs the host's Tailscale resolvers): write public resolvers into the
  container's `/etc/resolv.conf`. An `apt-get` from the hung attempt kept the apt lock until killed.
- **`podman exec` without `-i` drops stdin**, so `python3 - <<EOF` silently runs nothing.
- **PID 1 is `sleep infinity`, which doesn't reap**: every stopped server stays a `beam.smp` zombie. Harmless for
  `bench.sh` (a zombie's tick counters are frozen, so they cancel out), but recreate with `--init` next time.
- Once, `test/run.sh` hit `eaddrinuse` on port 3000 right after a variant's conformance run; it didn't reproduce.

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
| `bench.sh` | One measured point: fresh DB + server, warm-up, run, CPU per request. All settings via env (see its header), including `APP_CPUS`/`LG_CPUS` pinning |
| `interleave.sh` | Runs a configs file as forward + reversed cycles through `bench.sh` |
| `summarize.py` | Averages result lines per config, with the per-run spread |
| `make-variant.sh` | Copies the submission to a scratch dir, applies patches, builds it, so variants never touch the tree |
| `patches/experiment-switches.patch` | Env switches for experiments: `XPOOL_COUNT`, `XQ_TARGET`, `XQ_INTERVAL`, `XREPO_LOG`, `XPHX_LOG`, `XGC_EVERY`. Never commit it applied |
| `profile.sh` + `prof.exs` | `tprof` call-time profile of the prod build under load |
| `idle-memory.sh` + `idle_conns.py` | Memory per idle keep-alive connection |
| `port80.sh` | Binds port 80 as an unprivileged user with only the ambient capability, like `box/challenge.service` |
| `data/session-1/` | Every result line and loadgen summary from this session (`results.txt` is the index) |
| `data/session-2/` | The same for session 2 (knee ladder, batches 5 and 6) |

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
