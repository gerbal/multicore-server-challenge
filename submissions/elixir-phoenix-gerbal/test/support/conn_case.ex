defmodule ConduitWeb.ConnCase do
  @moduledoc "Tests that call the endpoint, with the database sandbox of `Conduit.DataCase`."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ConduitWeb.Endpoint

      use ConduitWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Conduit.Fixtures
      import ConduitWeb.ConnCase
    end
  end

  setup tags do
    Conduit.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("content-type", "application/json")}
  end

  @doc "Sends requests as `user`."
  def authenticate(conn, user) do
    Plug.Conn.put_req_header(conn, "authorization", "Token " <> Conduit.Accounts.sign_token(user))
  end
end
