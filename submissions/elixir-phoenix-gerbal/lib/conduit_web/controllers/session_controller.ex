defmodule ConduitWeb.SessionController do
  use ConduitWeb, :controller

  alias Conduit.Accounts

  def create(conn, %{"user" => %{} = credentials}) do
    with {:ok, user} <- Accounts.authenticate(credentials) do
      conn
      |> put_view(ConduitWeb.UserJSON)
      |> render(:show, user: user, token: Accounts.sign_token(user))
    end
  end

  def create(_conn, _params), do: {:error, :invalid_body}
end
