#!/usr/bin/env bash
# Runs the release in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# One Ecto pool of 10 connections per core, capped at 90 (Postgres allows 100), as in the Go example.
set -euo pipefail
cd "$(dirname "$0")"
pool=$(( 10 * $(nproc) )); (( pool <= 90 )) || pool=90
export DB_POOL_SIZE="${DB_POOL_SIZE:-$pool}"
# Serving directly, every user's keep-alive connection is a BEAM port; the default port limit (65,536) would cap them.
export ERL_AFLAGS="+Q 1000000 ${ERL_AFLAGS:-}"
export RELEASE_DISTRIBUTION=none LANG=C.UTF-8
exec _build/prod/rel/conduit/bin/conduit start
