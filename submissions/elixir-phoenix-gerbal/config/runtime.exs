import Config

if config_env() == :prod do
  fetch_env! = fn name -> System.get_env(name) || raise "environment variable #{name} is missing" end

  config :conduit, Conduit.Repo,
    url: fetch_env!.("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10"))

  config :joken, default_signer: fetch_env!.("JWT_SECRET")

  {:ok, ip} = System.get_env("HOST", "127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

  config :conduit, ConduitWeb.Endpoint,
    server: true,
    http: [
      ip: ip,
      port: String.to_integer(System.get_env("PORT", "3000")),
      # Nginx gzips JSON responses (level 1, over 1 KB). Left on, Bandit would compress first, at a higher level and
      # a higher CPU cost, and Nginx would pass the result through.
      http_options: [compress: false],
      # Keep idle keep-alive connections for 75 s, longer than Nginx's 60 s upstream keep-alive.
      thousand_island_options: [read_timeout: 75_000]
    ]
end
