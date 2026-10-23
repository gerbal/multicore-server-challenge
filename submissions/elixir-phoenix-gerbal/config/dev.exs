import Config

config :conduit, Conduit.Repo,
  url: System.get_env("DATABASE_URL", "postgres://conduit:conduit@localhost/conduit_dev"),
  pool_size: 10

config :conduit, ConduitWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4000], server: true

config :joken, default_signer: "dev-secret"
