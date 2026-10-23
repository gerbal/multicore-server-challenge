import Config

env! = fn name -> System.get_env(name) || raise "environment variable #{name} is missing" end

config :conduit, Conduit.Repo,
  url: env!.("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "80"))

config :conduit, :jwt_secret, env!.("JWT_SECRET")

{:ok, ip} = System.get_env("HOST", "127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

config :conduit, ConduitWeb.Endpoint,
  http: [
    ip: ip,
    port: String.to_integer(System.get_env("PORT", "3000")),
    # Keep idle keep-alive connections for 75 s, longer than Nginx's 60 s upstream keep-alive.
    thousand_island_options: [read_timeout: 75_000]
  ]
