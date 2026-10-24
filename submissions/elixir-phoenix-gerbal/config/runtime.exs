import Config

if config_env() == :prod do
  fetch_env! = fn name -> System.get_env(name) || raise "environment variable #{name} is missing" end

  config :conduit, Conduit.Repo,
    url: fetch_env!.("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
    # At saturation, let a query wait up to 200 ms for a connection (DBConnection's default is 50 ms) before the
    # pool starts shedding: latency has headroom under the 500 ms p95 limit, while every shed query is a 500.
    queue_target: 200,
    # Decoded text columns stay sub-binaries of the received packet instead of being copied; every request's heap is
    # collected when it ends (see `gc_every_n_keepalive_requests` below), so nothing holds on to a packet for long.
    types: Conduit.PostgrexTypes

  config :joken, default_signer: fetch_env!.("JWT_SECRET")

  {:ok, ip} = System.get_env("HOST", "127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

  config :conduit, ConduitWeb.Endpoint,
    server: true,
    http: [
      ip: ip,
      port: String.to_integer(System.get_env("PORT", "3000")),
      # Responses go out uncompressed: gzip is optional in SPEC.md and costs CPU on every response, which the box,
      # shared with Postgres, is shorter of than bandwidth.
      http_options: [compress: false],
      # Collect each connection's garbage after every request (Bandit's default is every 5th), so a user who is
      # thinking between pages doesn't hold on to the heap their last request built.
      http_1_options: [gc_every_n_keepalive_requests: 1],
      thousand_island_options: [
        # Clients hold one keep-alive connection each and think for up to 70 s between pages; don't close them first.
        read_timeout: 75_000,
        # Every user connects directly, so allow bursts of new connections (the box's somaxconn is 65535).
        transport_options: [backlog: 8192],
        # Start each connection process with a 4,181-word (33 KB) heap. The GC after every request shrinks the heap
        # back to this minimum, and a request needs about this much, so it no longer re-grows the heap through a
        # series of minor collections on every request. Costs ~35 KB per connection (~1 GB at 27,000 users).
        genserver_options: [spawn_opt: [min_heap_size: 4181]]
      ]
    ]
end
