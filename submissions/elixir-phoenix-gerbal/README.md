# Elixir: Phoenix + Ecto

**Front: direct**

A baseline written the way a Phoenix team would write it: contexts, Ecto schemas and changesets, composable Ecto
queries, JSON view modules and an ExUnit suite. It's a reference point for idiomatic Elixir rather than a contender:
the code is untuned, and the few runtime settings below are the ones a production deploy would set.

It serves the internet itself (`0.0.0.0:80`), as most Phoenix deployments do with Bandit, rather than behind Nginx.

| Piece | Version |
|---|---|
| Erlang/OTP | 29.1.2 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`) |
| Elixir | 1.20.4 (official release zip, sha256-pinned) |
| HTTP | Phoenix 1.8 on Bandit 1.13 |
| JSON | Elixir's built-in `JSON` (OTP's `:json` encoder) |
| Postgres | Ecto SQL 3.14 + Postgrex 0.22 |
| JWT | Joken 2.7 (HS256) |
| bcrypt | bcrypt_elixir 3.3, cost 10 |

Exact versions and hashes are in `mix.lock`. `install.sh` is the same toolchain installer as
[`elixir-raw-foovoo`](../elixir-raw-foovoo).

## Layout

| | |
|---|---|
| `Conduit.Accounts` | Sign-up, login, the current user, tokens (`Accounts.User`, `Accounts.Token`) |
| `Conduit.Profiles` | Profiles and follows (`Profiles.Follow`) |
| `Conduit.Blog` | Articles, the feed, favorites, comments, tags (`Blog.Article`, `Comment`, `Tag`, `Favorite`) |
| `ConduitWeb.*Controller` | One per resource; they call a context and return `{:error, reason}` to `FallbackController` |
| `ConduitWeb.*JSON` | The response shapes (`UserJSON`, `ProfileJSON`, `ArticleJSON`, `CommentJSON`, ...) |
| `ConduitWeb.Plugs` | `Authenticate` (required/optional token) and `Parsers` (`Plug.Parsers`, but bad JSON is a 422) |

Input is validated by changesets: required and non-blank fields, string types, passwords of at most 72 bytes
(bcrypt ignores the rest), unique usernames and emails through `unique_constraint`, and list paging through a
schemaless changeset. Changeset errors become RealWorld's `{"errors": {"body": [...]}}` with messages like
`"email has already been taken"`.

## Queries

The queries are Ecto's, not SPEC.md's SQL strings, but they keep the reference SQL's shape and results:

- Lists choose a page of ids first, newest first, from the narrowest index for the filter, then load that page. A
  tag's entries in `article_tags` and a user's in `favorites` are walked directly (`(tag_id, article_id)`,
  `(user_id, article_id)`), with the tag or user id as a scalar subquery, like the reference SQL, rather than joining
  through `articles`. On the full seed that made a popular tag's page ids 4x and its capped count 5x cheaper in
  Postgres, and in interleaved runs (6,000 users, 8 threads) Postgres CPU per request fell 21% (0.549 → 0.435 ms);
  the box stopped saturating at that load (7,364 → 7,888 req/s, p95 115 → 19 ms).
- The page of ids and the articles are two statements, the second loading by id list (`where: a.id in ^ids`). With
  the page's `LIMIT`/`OFFSET` as parameters, Postgres never reuses a generic plan for the big article query (it
  can't bound the rows), so it planned it on every call: 0.56 ms of planning for 0.30 ms of execution for the
  global list. By id list it is planned once per connection. Interleaved at saturation (7,500 users): 8,132 →
  8,564 req/s, p99 341 → 247 ms, 13% less Postgres CPU per request, for 1% more app CPU.
- Responses are encoded with Elixir's built-in `JSON` (OTP's `:json`) instead of Jason (`config :phoenix,
  :json_library, JSON`). String escaping was the largest single app cost in a profile at load; interleaved at
  saturation (7,500 users) it took 8,447 → 8,679 req/s with 4% less app CPU per request, every run faster.
- An article's comments are one statement: the article by slug, left-lateral-joined to its newest 100 comments
  (`left_lateral_join: c in subquery(newest)` with `parent_as(:article)`), so an article without comments is a row
  with a nil comment and an unknown slug is no row (404). Every `Repo` call costs a pool checkout, a planner pass and
  a round trip; dropping the separate slug lookup on the most frequent request took 8,651 → 8,900 req/s (7,500
  users, interleaved), 3.5% less app CPU per request. The favorite count and the viewer's `favorited` and `following` are correlated subqueries in the select
  (`exists(subquery(...))` with `parent_as`), so they run once per article on the page.
- The feed takes each followed author's newest `limit + offset` articles through a lateral join and merges them,
  so it walks `articles_author_idx` instead of sorting everything the followed authors ever wrote.
- `articlesCount` is `count(*)` over a subquery limited to 1,000 rows.
- Tag names are aggregated in the same query (a correlated subquery with `array_agg(... ORDER BY name)`), like the
  reference's `ARRAY(...)` column. A `many_to_many` preload would be the more obvious Ecto, but it costs a second
  round trip per page: in local interleaved runs (1,700 users) aggregating them took 1,984 → 2,131 req/s and p95
  220 → 114 ms, with 9% less app and 7% less Postgres CPU per request.
- Article and comment queries select only the columns the JSON sends (`struct(a, ^fields)` merged with the computed
  fields): lists leave out the ~1 KB `body`, and authors leave out `email` and `password_hash`. In interleaved runs
  on the full seed (6,000 users, 8 threads) this took 6,984 → 7,174 req/s and p95 172 → 142 ms, with every run of
  it faster than every run without it.
- Publishing is a single `Repo.insert`. `prepare_changes` takes the id from the sequence, sets the slug and upserts
  and links the tags inside the insert's transaction. Slugs are computed in Elixir, byte-for-byte the same as
  SPEC.md's `SLUGIFY`.

## Multicore model

One BEAM node with the default schedulers (one per core): Bandit runs a process per connection, and bcrypt's NIF
runs on the dirty CPU schedulers. One Ecto pool of `DB_POOL_SIZE` connections, 10 per core capped at 90 (80 on the
8-core box), like the Go example. Ecto prepares and caches each query per connection.

## Settings beyond the defaults

Serving directly means one keep-alive connection per user, tens of thousands of them, mostly idle:

- `+Q 1000000` in `start.sh`: every TCP socket is a BEAM port, and the default limit of 65,536 would cap the number
  of users. (The process limit, about a million, and ThousandIsland's default 100 × 16,384 connections are enough.)
- Bandit's `read_timeout` is 75 s, longer than a user's maximum 70 s think time, so the server never closes an idle
  user's connection first.
- The listen backlog is 8,192 (ThousandIsland's default is 1,024; the box allows 65,535), for bursts of new
  connections.
- Response compression is off (`http_options: [compress: false]`). Gzip is optional in SPEC.md, and on this box CPU,
  shared with Postgres, is scarcer than bandwidth. In a local test on a 4-core VM (the app, Postgres and the load
  generator shared the cores; dev seed, think time scaled to 0.2, two interleaved runs each, 1,700 users) turning it
  off gave 1,816 → 2,026 req/s, p95 317 → 193 ms, p99 424 → 268 ms and errors 1.14% → 0%, with 15% less app CPU per
  request.
- Ecto's `queue_target` is 200 ms (DBConnection's default is 50 ms). At saturation a query then waits for a
  connection instead of being shed as a 500, which the error limit punishes long before the latency limit. In local
  300 s holds at real pacing (full seed, app + Postgres pinned to 8 threads, 27,000 users), the default failed both
  runs on errors (1.5%, 4.6%) and 200 ms passed both (0% errors, p95 409 ms). Below saturation the pool never queues
  that long, so nothing changes there.
- Each connection process starts with a 4,181-word heap (`genserver_options: [spawn_opt: [min_heap_size: 4181]]`),
  and Postgrex decodes text columns by reference (`Conduit.PostgrexTypes`, `decode_binary: :reference`) instead of
  copying them out of the received packet. The first stops every request from re-growing a heap that the
  per-request GC just shrank; the second is safe because that GC runs after every request. Together, interleaved on
  the full seed (6,000 users, 8 threads, 4 runs each): 7,139 → 7,381 req/s, p95 152 → 108 ms, 6% less app CPU per
  request, every run faster. The price is memory: ~35 KB more per connection, 918 MB → 1,863 MB at 27,000 users.
- `limit` and `offset` must be plain digits (`Conduit.Types.PlainInteger`); Ecto's `:integer` would also take `+5`.
- Logger level `:warning` in prod.

## Behavior that differs from the reference

- A field that is only whitespace counts as blank, as Ecto treats it by default. A username of `" "` is a 422
  here; the reference only rejects `""`.
- An `offset` too large for the feed's `limit + offset` to fit in a bigint (over 2^63 − 101) is a 422.

## Build, run and test

```bash
sudo bash submissions/elixir-phoenix-gerbal/install.sh
bash test/run.sh submissions/elixir-phoenix-gerbal                   # conformance suite

cd submissions/elixir-phoenix-gerbal
TEST_DATABASE_URL=postgres://postgres:postgres@localhost/conduit_test mix test
```

`mix test` drops and recreates its own database, loads [`schema.sql`](../../schema.sql) into it with `psql`, and runs
each test in a rolled-back sandbox transaction. It needs a role that can create databases, and it hashes at cost 4
to keep the suite fast.

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `HOST` (127.0.0.1; `0.0.0.0` on the box), `PORT` (3000; `80` on
the box), `DB_POOL_SIZE`. Binding port 80 needs `CAP_NET_BIND_SERVICE`, which the box's systemd unit grants.
