defmodule Conduit.MixProject do
  use Mix.Project

  def project do
    [
      app: :conduit,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [conduit: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [mod: {Conduit.Application, []}, extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.13"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.7"},
      {:bcrypt_elixir, "~> 3.3"}
    ]
  end
end
