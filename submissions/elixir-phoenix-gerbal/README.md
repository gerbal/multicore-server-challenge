# Elixir: Phoenix + Ecto

**Front: nginx**

A plain, unoptimized baseline in the spirit of the [examples](../../examples): the language's most popular web
framework used the way its guides use it, the reference SQL from [SPEC.md](../../SPEC.md) verbatim, and no tuning
beyond the pool size. It's meant as a starting point and a point of comparison, not a contender.

| Piece | Version |
|---|---|
| Erlang/OTP | 28.5.0.8 (hex.pm's official Ubuntu 24.04 build, sha256-pinned in `install.sh`) |
| Elixir | 1.19.6 (official release zip, sha256-pinned) |
| HTTP | Phoenix 1.8 on Bandit 1.x (router, pipelines, controllers, `action_fallback`) |
| JSON | Jason |
| Postgres | Ecto SQL 3.x + Postgrex (`Repo.query/2` with the reference SQL, no schemas) |
| JWT | Joken 2.x (HS256; `exp` required and checked) |
| bcrypt | bcrypt_elixir 3.x, cost 10 |

Exact dependency versions and hashes are in `mix.lock`. `install.sh` is the same toolchain installer as
[`elixir-raw-foovoo`](../elixir-raw-foovoo).

## Multicore model

One BEAM node with the default schedulers (one per core), so Bandit's one-process-per-connection model and
bcrypt's NIF (on dirty CPU schedulers) spread over every core with no configuration. One Ecto pool of
`DB_POOL_SIZE` connections, 10 per core capped at 90 (80 on the 8-core box), like the Go example.

## Settings beyond the defaults

- Bandit's `read_timeout` is 75 s so idle keep-alive connections outlive Nginx's 60 s upstream keep-alive.
- Request bodies are read and decoded in the controllers (`ConduitWeb.Body`) instead of with `Plug.Parsers`, so a
  malformed or empty body gives 422 instead of Plug's 400.
- Unknown routes and crashes render the `{"errors": {"body": [...]}}` shape (`ConduitWeb.ErrorJSON`).
- Logger level `:warning` (no per-request logging).
- Passwords over 72 bytes are rejected on register and password change (bcrypt ignores the rest).

## Build and run

```bash
sudo bash submissions/elixir-phoenix-gerbal/install.sh
bash test/run.sh submissions/elixir-phoenix-gerbal
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `HOST` (127.0.0.1), `PORT` (3000), `DB_POOL_SIZE`.
