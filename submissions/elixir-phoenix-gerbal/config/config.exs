import Config

config :conduit, ecto_repos: [Conduit.Repo]

config :conduit, ConduitWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: ConduitWeb.ErrorJSON], layout: false]

config :phoenix, :json_library, Jason

# Cost 10 on every hash (rule 7).
config :bcrypt_elixir, log_rounds: 10

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n", metadata: [:request_id]

import_config "#{config_env()}.exs"
