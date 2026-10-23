defmodule ConduitWeb.TagController do
  use ConduitWeb, :controller

  def index(conn, _params) do
    tags = for [name] <- Repo.all_rows(SQL.tags(), []), do: name
    reply(conn, 200, %{tags: tags})
  end
end
