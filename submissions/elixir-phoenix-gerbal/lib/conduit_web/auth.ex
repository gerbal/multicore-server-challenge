defmodule ConduitWeb.Auth do
  @moduledoc """
  `Authorization: Token <jwt>`. Assigns `:viewer` (user id, or 0 when anonymous) and `:token`.
  Required: a missing or invalid token gives 401. Optional: no header is anonymous, an invalid one gives 401.
  """
  import Plug.Conn

  def authenticate(conn, mode) do
    case {get_req_header(conn, "authorization"), mode} do
      {[], :optional} ->
        conn |> assign(:viewer, 0) |> assign(:token, nil)

      {["Token " <> token], _} ->
        case Conduit.Token.verify(token) do
          {:ok, id} -> conn |> assign(:viewer, id) |> assign(:token, token)
          :error -> unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn), do: conn |> ConduitWeb.Reply.error(401, "unauthorized") |> halt()
end
