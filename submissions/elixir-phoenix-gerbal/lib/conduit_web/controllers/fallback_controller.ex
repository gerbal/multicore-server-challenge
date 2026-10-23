defmodule ConduitWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, status, message}), do: ConduitWeb.Reply.error(conn, status, message)
  def call(conn, :error), do: ConduitWeb.Reply.error(conn, 422, "invalid body")
end
