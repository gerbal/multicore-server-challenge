#!/usr/bin/env bash
# Runs the release in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# One Ecto pool of 10 connections per core, capped at 90 (Postgres allows 100), as in the Go example.
set -euo pipefail
cd "$(dirname "$0")"
pool=$(( 10 * $(nproc) )); (( pool <= 90 )) || pool=90
export DB_POOL_SIZE="${DB_POOL_SIZE:-$pool}"
export RELEASE_DISTRIBUTION=none LANG=C.UTF-8
exec _build/prod/rel/conduit/bin/conduit start
