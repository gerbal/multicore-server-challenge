defmodule Conduit.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [Conduit.Repo, ConduitWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: Conduit.Supervisor)
  end
end
