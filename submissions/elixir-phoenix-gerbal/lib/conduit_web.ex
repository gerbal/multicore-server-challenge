defmodule ConduitWeb do
  @moduledoc "`use ConduitWeb, :controller`."

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
      import ConduitWeb.Reply
      alias Conduit.{Repo, SQL}
      alias ConduitWeb.Body
      action_fallback ConduitWeb.FallbackController
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
