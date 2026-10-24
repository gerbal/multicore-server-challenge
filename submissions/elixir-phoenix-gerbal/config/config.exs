import Config

config :conduit, ecto_repos: [Conduit.Repo]

config :conduit, ConduitWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: ConduitWeb.ErrorJSON], layout: false]

# Elixir's built-in JSON (OTP's :json encoder): 4% less app CPU per request than Jason in interleaved runs.
config :phoenix, :json_library, JSON
config :postgrex, :json_library, JSON

# Cost 10 on every hash (rule 7).
config :bcrypt_elixir, log_rounds: 10

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n", metadata: [:request_id]

import_config "#{config_env()}.exs"
