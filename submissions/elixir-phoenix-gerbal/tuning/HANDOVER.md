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
- Conformance: 197/197 on the dev seed (local Postgres 16; CI uses 18). `mix test`: 86 tests. `install.sh` and
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
| `fd00b5d` | Ecto `queue_target` 200 ms, from the real-pacing holds below |
| `8d3164a` | Erlang/OTP 29.1.2 and Elixir 1.20.4 (batch 10) |
| `d208fa0` | 4,181-word connection heap + Postgrex reference decoding (batches 11-12); dependency survey |
| `f6db6fa` | List filters walk their join tables' indexes (batch 15) |
| `ff9d8a6` | List pages loaded by id list, a second statement (batch 16) |
| `b8914ee` | Elixir's built-in `JSON` instead of Jason (batch 17) |
| `0feb89f` | An article's comments in one statement (batch 18) |
| `a7fe6ad` | Ecto pool of 3 connections per core (batches 19-21) |
| `f8039c5` | Handover: batches 13-21, leaderboard calibration |
| `fc264c6` | A list's capped count read with its page of ids (batch 22) |
| `60e6e88` | Normal schedulers on 5/8 of the cores, `+S 5:5` (batch 23) |
| `566695b` | Handover: batches 22-26 and the held score |
| `9fdc40b`, `1ff1742` | Idiom review: race-safe writes (404 on a lost race, 204 for a delete that finds nothing), one whitespace policy, 18 more tests |
| `2f8aca3` | `phoenix_ecto` |
| `18a8607` | Styler as a `mix format` plugin |
| `fac6cf2` | `PlainInteger` and the token's `sub` matched without a regex (a regex literal is recompiled per call on OTP 28+) |
| `51ad1dd` | What `mix phx.new` has and this lacked: `ConduitWeb.Telemetry`, dev code reloading, `:runtime_tools`, `mix precommit`; VM flags moved from `start.sh` into `rel/` and the pool default into `runtime.exs` (batch 27) |
| `c9952fe` | `perf.sh` + `perf-layers.py`: perf profiles at full load |
| (this commit) | The viewer's flags as left joins; heaps and binaries on the `gf` allocator strategy (batches 28-29) |

### What the shipped config sets, and why

| Setting | Where | Evidence |
|---|---|---|
| Compression off | `runtime.exs` | Strong: two interleaved runs each at 1,700 users, 1,816 → 2,026 req/s, p95 317 → 193 ms, errors 1.14% → 0% |
| `+Q 1000000` | `rel/vm.args.eex` | Required: each user's socket is a port; the default 65,536 caps users. Verified the release boots with a 1,048,576 port limit |
| Listen backlog 8,192 | `runtime.exs` | Cheap headroom for direct connection bursts; the box's `somaxconn` is 65,535. Not load-tested |
| GC after every keep-alive request | `runtime.exs` | Memory: 80 → 14 KB per idle connection (15,000 idle connections). CPU cost: see batch 4 below |
| `read_timeout` 75 s | `runtime.exs` | Longer than the workload's 70 s maximum think time, so the server never closes a thinking user |
| Ecto `queue_target` 200 ms | `runtime.exs` | Strong at real pacing: batch 8 (session 2). The default sheds queries as 500s at saturation |
| Connection heap `min_heap_size: 4181` | `runtime.exs` | Strong: batches 11-12. ~35 KB more per connection |
| Postgrex `decode_binary: :reference` | `Conduit.PostgrexTypes` | Strong: batches 11-12 |
| Pool 3 per core, capped at 90 (24 on the box) | `config/runtime.exs` | Strong at real pacing: batches 19-21 |
| Normal schedulers on 5/8 of the cores | `rel/env.sh.eex` | Moderate: lower app CPU per request in batches 19, 21 and 23 |
| A list's count in its ids statement | `Conduit.Blog` | Strong: batch 22 |
| Filters walk join-table indexes; pages loaded by id list | `Conduit.Blog` | Strong: batches 15-16 |
| Comments in one statement (lateral join) | `Conduit.Blog` | Strong: batch 18 |
| Elixir's built-in `JSON` | `config.exs` | Strong: batch 17 |
| Heaps and binaries on the `gf` allocation strategy | `rel/vm.args.eex` | Strong: batches 28-29 (app CPU -3% at 37k and 39k), less memory |
| The viewer's `favorited`/`following` as left joins | `Conduit.Blog` | Moderate: batches 28-29 (app CPU -3.1% / -1.8%); with gf -4.7% at 39k |
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

### Exception logging under overload (batch 9, probes at 30,000 users, 2 runs each)

| Config | req/s | p95 | Errors | App CPU/req | TCP connects | Server log lines |
|---|---:|---:|---:|---:|---:|---:|
| shipped (`queue_target` 200) | 7,026 | 776 ms ✗ | 0.09% | 0.526 ms | ~32k | 14-23k |
| … `log_exceptions_with_status_codes: []` | 6,997 | 763 ms ✗ | 0.01% | 0.527 ms | ~32k | 0 |
| `queue_target` 50 | 7,554 | 292 ms | 28.8% ✗ | 0.582 ms | ~184k | 107-121k |
| … `log_exceptions_with_status_codes: []` | 7,609 | 245 ms | 16.1% ✗ | 0.509 ms | ~117k | 0 |

With the old 50 ms target, logging every shed query (Phoenix renders the error, re-raises, Bandit formats the
stacktrace) cost 13% app CPU per request and much of the error rate. With 200 ms almost nothing is shed, so logging
costs nothing measurable; both fail at 30k on latency. Not shipped: it would only trade away production error logs.
Every raised exception also closes the keep-alive connection (`Bandit.Pipeline` returns `{:error, _}`); no option
changes that.

### Toolchain: OTP 28.5.0.8 / Elixir 1.19.6 → OTP 29.1.2 / Elixir 1.20.4 (batch 10, 6,000 users, 4 runs each)

7,094 vs 7,056 req/s, app CPU 0.518 vs 0.518 ms per request: no change. The app compiles without warnings under
1.20's type checker; deps warn only about `jose`'s deprecated `catch`. A release bundles its ERTS, so the old build
(`/srv/v/switches-otp28`) stays runnable after the upgrade for comparisons like this.

### The dependency survey and the shortlist (batches 11-12, 6,000 users, 4 runs each)

A survey of every dependency's options in `deps/` (with each default read from source) gave a ranked shortlist,
implemented as switches in `experiment-switches.patch` (`XMIN_HEAP`, `XPG_REF`, `XSIGNER`; busy-wait via
`ERL_AFLAGS`, which `interleave.sh` now accepts quoted). Batch 11 (OTP 29 base 7,257 req/s, 0.507 ms app CPU):

| Config | req/s | p95 | App CPU/req | Verdict |
|---|---:|---:|---:|---|
| `+sbwt none +sbwtdcpu none +sbwtdio none` | 7,262 | 129 ms | 0.506 ms | no effect on 8 threads either |
| connection heap `min_heap_size: 4181` | 7,307 | 117 ms | 0.490 ms | -3.4% app CPU, every run below every base run |
| prebuilt Joken signer (`:persistent_term`) | 7,241 | 131 ms | 0.506 ms | no effect |
| Postgrex `decode_binary: :reference` | 7,306 | 123 ms | 0.497 ms | -2% app CPU, every run below every base run |

Batch 12, both together:

| Config | req/s | p95 | p99 | App CPU/req | Runs (req/s) |
|---|---:|---:|---:|---:|---|
| base | 7,139 | 152 ms | 183 ms | 0.514 ms | 7,112 / 7,223 / 7,053 / 7,167 |
| **heap 4181 + reference decoding** | **7,381** | **108 ms** | **134 ms** | **0.483 ms** | 7,348 / 7,387 / 7,355 / 7,433 |

Real-pacing probes at 27,000 users: p95 165 → 77 ms, peak BEAM RSS 918 → 1,863 MB (~35 KB per connection, the
33 KB heap plus bookkeeping). **Shipped both.** Why the heap helps: the GC after every request shrinks each heap back
to the minimum, so every request re-grew it through several minor collections. Reference decoding was checked live:
`body` values point into the 2 KB receive buffer instead of being copies (values under 64 bytes are copied either
way). Not tried yet: 2,584 or 6,765 words, which trade the same CPU against memory differently.

Other survey findings, not benchmarked: `Plug.RequestId` and the Phoenix/Ecto log handlers do per-request work that
is thrown away at `:warning`, about 1% each (see batch 5's logging run); `:telemetry.persist/0` would move
telemetry handlers to `persistent_term`; the logger handler goes synchronous above a 10-message queue, which
matters only while errors are being logged. Jason, Ecto's query cache, `prepare: :named` and `plan_cache_mode`
are already the best settings.

### Postgres per request, then app per request, then pool size (batches 13-21)

The leaderboard (`LEADERBOARD.md`) showed where the gap was: its top entries spend ~0.2-0.25 ms of Postgres CPU per
request; this build spent ~0.55 ms. Each step below was interleaved (4 runs each unless stated) and won in every run.

| Batch | Change | Load | req/s | p95 | App / PG CPU per request |
|---|---|---|---|---|---|
| 13 | heap 2,584 / 4,181 / 6,765 words | 6,000 users, 0.2 | 7,344 / 7,304 / 7,395 | 112 / 115 / 113 ms | a tie: not changed |
| 14 | `plan_cache_mode = force_generic_plan` (2 runs) | 6,000, 0.2 | 7,326 → **1,418** | 119 → 5,204 ms | the global list's generic plan scans every article |
| 15 | filters walk `article_tags` / `favorites` directly | 6,000, 0.2 | 7,364 → 7,888 | 115 → 19 ms | 0.487 / 0.549 → 0.517 / 0.435 (no longer saturated) |
| 16 | page ids, then articles `where: a.id in ^ids` | 7,500, 0.2 | 8,132 → 8,564 | 269 → 220 ms | 0.497 / 0.440 → 0.503 / 0.384 |
| 17 | Elixir `JSON` instead of Jason | 7,500, 0.2 | 8,447 → 8,679 | 242 → 201 ms | 0.512 → 0.492 app |
| 18 | comments in one statement | 7,500, 0.2 | 8,651 → 8,900 | | 0.491 / 0.385 → 0.474 / 0.379 |
| 19 | pool 80 → 24 (2 runs; also `+S 5:5`, `6:6`, sbwt, pool 12) | 34,000, real | 8,639 → 8,972 | 373 → 45 ms | 0.487 / 0.384 → 0.504 / 0.329 |
| 20 | pool 16 / 24 / 32 / 40, ± `+S` (2 runs) | 38,000, real | all fail; 24 the only pool size with 0% errors | 800-1,050 ms | |
| 21 | pool 24 ± `+S 5:5` / `6:6` (2 runs) | 36,000, real | 9,164 / 9,113 / 9,154 | 391 / 398 / 402 ms | a tie: `+S` not shipped |

How the Postgres work was found: log every statement under load, then for each hot one compare `EXPLAIN ANALYZE`
planning vs execution time, and check `pg_prepared_statements` (`generic_plans`, `custom_plans`) after preparing it
and executing it 10 times in one session. Statements whose generic plan is fine switch to it after 5 executions;
the global and tag lists never did (`LIMIT`/`OFFSET` as parameters), and their planning was ~25% of all Postgres
time. Warm the session before trusting `EXPLAIN` planning times: a fresh `psql` plans 3-5x slower.

The app profile (`profile.sh` at 2,500 users; at 7,000 the traced server overloads and the profile fills with error
handling): socket writes 14% (one per response, one per Postgres statement), Jason escaping ~12% (fixed by batch
17), the Ecto planner and DBConnection checkout ~5% (both per `Repo` call), then a flat tail.

### Calibration against the leaderboard

`elixir-raw-foovoo` (32,000 on the box) built and run on this rig, interleaved with this build, then 300 s holds
stepping down 5% as the real search does:

| | Probes (60 s) | 300 s holds | Rig score | Box |
|---|---|---|---:|---:|
| `elixir-raw-foovoo` | 44k, 50k pass; 56k fails | 48k, 45.6k, 43.3k fail; **41.1k passes** | 41,100 | 32,000 |
| this build (`a7fe6ad`) | 34k passes; 36k, 38k fail | 36k fails (p95 718 ms); **34.2k passes** (p95 276 ms) | 34,200 | ≈ 26,600 |

So box ≈ 0.78 × this rig, and this build would hold about 26-27k on the box: above the four video examples (Go 24k,
Rust 22k, Java 21k) and at ~83% of `elixir-raw-foovoo`. Per request on the rig: app 0.48-0.51 ms vs its 0.24,
Postgres 0.33-0.34 vs its 0.33. Postgres is at parity; the remaining gap is the framework's CPU per request.
(One reference and one hold each: ±10%. `elixir-raw-foovoo` was built with OTP 29, not its pinned 28.)

### The last round (batches 22-26) and the held score

| Batch | Change | Load (real pacing) | Result |
|---|---|---|---|
| 22 | list count in the ids statement | 36,000 | 9,034 → 9,292 req/s, p95 481 → 236 ms: **shipped** |
| 23 | logging off / `+S 5:5` / heap 2,584 | 37,000 | `+S 5:5`: app CPU 0.476 → 0.458 ms, p95 360 → 290 ms: **shipped**; the others within noise or worse |
| 24 | `inet_backend: :socket` on the listener | 38,000 | app CPU +3.7%, p95 486 → 583 ms: no |
| 25 | GC every 1 / 2 / 5 requests (with the 4,181-word heap) | 38,000 | every request stays best (p95 477 vs 556 / 536 ms) |
| 26 | `+SDcpu 2:2` / busy-wait off (with `+S 5:5`) | 38,000 | 9,373 / 9,440 / 9,436 req/s: noise |
| 27 | VM flags in `rel/` and the pool default in `runtime.exs` instead of `start.sh`, plus `ConduitWeb.Telemetry` and `:runtime_tools` | 37,000 | 9,611 → 9,593 req/s, app CPU 0.444 → 0.449 ms, runs overlapping: noise (same `-S 5:5 -Q 1000000` on the beam command line, 24 connections) |
| 28 | From the perf profile: viewer flags as left joins (`joins`); allocators `gf`, 20 MB carriers (`mbcs`), a 4 GB super carrier (`scs`) | 37,000 | base 9,555 req/s, app 0.447 ms, p95 193 ms; joins 9,797 / 0.433 / 45; gf 9,729 / 0.434 / 66; mbcs 9,646 / 0.443; scs 9,698 / 0.442. joins and gf won both runs: **shipped**; mbcs and scs noise. (`+MHacul 0` alone turns into gf.) |
| 29 | joins, gf and both, base mid-batch | 39,000 | base 9,649 req/s, app 0.448 ms, p95 519 ms; joins 9,775 / 0.440 / 406; gf 9,806 / 0.434 / 353; both 9,901 / 0.427 / 371. joins' Postgres saving in batch 28 (-4%) didn't repeat. Peak RSS at 37,000: base 2,474 MB, gf 2,237, both 2,300 |

**Held score of `60e6e88` on this rig: 37,000** (probe at 39,000 failed on p95; 300 s hold at 37,000 passed,
p95 457 ms, p99 633 ms, 0% errors, 9,221 req/s). With the calibration above (box ≈ 0.78 × rig), **≈ 29,000 on
the box**, against `elixir-raw-foovoo`'s 32,000. Per request on the rig now: app ~0.46 ms, Postgres ~0.33 ms.

The latest profile, grouped by layer (`profile.sh` at 2,500 users): Ecto 18% (the planner's cache-key walk on every
`Repo` call ~10%, loading rows the rest), generic `Enum`/`maps`/`lists` work 27% (mostly on Ecto's behalf), JSON
10%, socket writes 7%, Postgrex/DBConnection 5%, Bandit + Plug + Phoenix 7%, bcrypt 4%, JWT 2%, timestamps 3%.
What's left is the framework's per-call work; the dials are exhausted.

### A perf profile at full load (`perf.sh`, 37,000 users, real pacing)

`tprof` traces every call, so it only runs at 2,500 users and never sees the runtime's C code. `perf.sh` samples
user space at 499 Hz per thread for 20 s of a normal `bench.sh` window (9,410 req/s, 0.456 ms app CPU; normal for
this build) with the JIT's perf map, so Erlang and C share one profile. Text results in `data/session-2/perf-p1/`
(`layers.txt`, `inclusive.txt`, `flat.txt`). Self time by layer, of 44,855 samples:

| Layer | Self | Notes |
|---|---:|---|
| Runtime C: BIFs, maps, ETS, comparisons | 14.8% | `query_lookup`'s ETS key hash and compare alone ~1.4% |
| Unattributed native (libc, `[unknown]`) | 15.0% | ~6% unresolved addresses |
| Memory allocators | 10.2% | `aoff_get_free_block`, `rbt_insert`, `mbc_*`; from socket reads/sends, Postgrex messages, the per-request GC |
| GC | 10.0% | `do_minor` 6%; triggered mostly while decoding rows (timestamps, text) and by Bandit's GC after each request |
| bcrypt | 6.4% | Cost 10 is a rule |
| Ecto (Erlang) | 6.3% | 37% inclusive; the planner (`Planner.query/6`) 11.5% inclusive, 8.3% of it planning subqueries |
| Socket I/O (C) | 5.7% | iolist sizing and vectors for `port_command` |
| JIT helpers (map lookups, BIF calls) | 5.5% | |
| Elixir stdlib | 5.4% | mostly `Enum` on Ecto's behalf |
| Scheduler | 4.0% | |
| Message/term copying | 2.7% | `query_lookup` copying the cached query out of ETS 0.7%; `DBConnection.Holder` |
| JSON | 2.6% | 5.1% inclusive |
| Bandit, Phoenix, Plug, Postgrex, DBConnection, Joken, our code | 0.2-1.8% each | Joken verify 3.5% inclusive; `GET /api/tags` 6.4% inclusive for 200 tags |

New against the `tprof` picture: about a fifth of the CPU is the runtime's memory management (allocators + GC), and
Ecto's cache lookup costs real time in ETS hashing and copying, not only in the planner's walk. Candidates, all within
the rules: allocator flags (`+M...` strategies and carrier sizes, a flags-only batch); fewer `subquery` expressions per
article query (the viewer's `favorited`/`following` as left joins on the primary keys rather than `exists(subquery)`),
which cuts the planner's per-call subquery planning; and nothing obvious for GC beyond the heap and GC-interval dials
already measured (batches 11, 23, 25). Batches 28-29 tried the first two: the `gf` allocator strategy and the left
joins both shipped (app CPU about -3% each, -4.7% together at 39,000 users); bigger carriers and a super carrier
were noise. A held-score search with both hasn't been run yet.

## Open questions, in the order I'd tackle them

After session 2:

- Fewer `Repo` calls is still the lever (each costs a planner pass, a pool checkout and a socket write each way).
  Favorite/unfavorite run three, follow/unfollow two; both are rare writes. The article page and the comments
  page are one each, lists two.
- Timestamps formatted by Postgres (`to_char` in the select) would skip `DateTime` decoding and `to_iso8601` (3%),
  at some Postgres CPU and readability cost.

Done or settled in session 2: questions 1-8 of session 1 below, the heap size, the GC interval, logging, busy-wait,
scheduler counts, dirty schedulers, the socket backend, generic plans.

- **App CPU per request is the gap** (0.5 vs 0.24 ms). Profile again with the current build; the per-`Repo`-call
  overhead (planner, checkout, a socket write each) argues for fewer statements: lists still run three (ids,
  articles, count), favorites three.
- Heap back to 2,584 words: batch 13 showed no CPU difference and it saves ~13 KB per connection.

- **The overload cliff.** From 26k to 30k users errors go 0% → 30%, and every 500 closes the user's connection,
  so the load turns into a reconnect storm. Prod logs at `:warning`, so each shed query also writes a ~20-line
  error with a stack trace (6,743 of them at 30k): cost of logging under overload is worth measuring.
- **CPU per request is what's left.** Profile at saturation on the 8-thread setup (`profile.sh`) before guessing.
  Candidates: the per-article correlated subqueries (favorite count, `favorited`, `following`) vs one aggregate
  join, and `GET /api/articles/:slug/comments` (the most frequent request with the article lookup) as one query
  instead of two.
- Logging off once more with `ROUNDS=3` if a 1% win is worth shipping; it's a standard production setting either way.
- `+S 5:5` trims app CPU 3% with pool 24 but didn't move throughput; retest if the app share grows.
- A bundle of the ~1% items (Phoenix logger off, Ecto `log: false`, `:telemetry.persist()`, no `Plug.RequestId`),
  `ROUNDS=3`.

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
- **`test/run.sh` sometimes fails with `eaddrinuse` on port 3000** in the container (four times, always the first
  run after load; reruns pass). The container's `ip_local_port_range` is 1024-65535 (the box's sysctl), so port
  3000 can be some live outgoing socket's ephemeral port; TIME_WAIT alone doesn't block the bind (tested). Run
  local conformance with `PORT=999` (outside the range; root in the container). The box serves port 80 and CI
  uses stock ranges, so neither is affected.
- `pkill -f` patterns in a `podman exec` command line match the wrapper's own text (database names and paths
  count): kill by PID instead.

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
| `patches/experiment-switches.patch` | Env switches for experiments: `XPOOL_COUNT`, `XQ_TARGET`, `XQ_INTERVAL`, `XREPO_LOG`, `XPHX_LOG`, `XGC_EVERY`, `XLOG_EXC`, `XMIN_HEAP`, `XPG_REF` (`false` = default types), `XSIGNER=prebuilt`. Never commit it applied |
| `profile.sh` + `prof.exs` | `tprof` call-time profile of the prod build under load |
| `perf.sh` + `perf-layers.py` | Linux `perf` profile of one `bench.sh` run at full load, from a helper container (seccomp blocks `perf` in the bench container); flame graph, flat profile, per-layer and per-caller summaries. Needs the `localhost/perf-tools` image (a Fedora toolbox with `perf` and `js-d3-flame-graph`, `podman commit`ed) |
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
