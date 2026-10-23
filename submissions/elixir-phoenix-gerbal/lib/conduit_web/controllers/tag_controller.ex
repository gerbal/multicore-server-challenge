defmodule ConduitWeb.TagController do
  use ConduitWeb, :controller

  alias Conduit.Blog

  def index(conn, _params), do: render(conn, :index, tags: Blog.list_tags())
end
