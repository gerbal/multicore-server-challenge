defmodule ConduitWeb.Reply do
  @moduledoc "JSON responses, the error shape, and the User/Profile/Article/Comment objects."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def reply(conn, status, data), do: conn |> put_status(status) |> json(data)

  def error(conn, status, message), do: reply(conn, status, %{errors: %{body: [message]}})

  def no_content(conn), do: send_resp(conn, 204, "")

  def user([_id, username, email, bio, image], token),
    do: %{username: username, email: email, bio: bio, image: image, token: token}

  def profile(username, bio, image, following),
    do: %{username: username, bio: bio, image: image, following: following}

  # A row of ARTICLE_LIST_SELECT (13 columns) or ARTICLE_FULL_SELECT (14: body after description).
  def article([
        _id,
        slug,
        title,
        description,
        created,
        updated,
        tags,
        count,
        favorited,
        username,
        bio,
        image,
        following
      ]) do
    %{
      slug: slug,
      title: title,
      description: description,
      tagList: tags,
      createdAt: timestamp(created),
      updatedAt: timestamp(updated),
      favorited: favorited,
      favoritesCount: count,
      author: profile(username, bio, image, following)
    }
  end

  def article([id, slug, title, description, body | rest]),
    do: [id, slug, title, description | rest] |> article() |> Map.put(:body, body)

  def comment([id, body, created, updated, username, bio, image, following]) do
    %{
      id: id,
      body: body,
      createdAt: timestamp(created),
      updatedAt: timestamp(updated),
      author: profile(username, bio, image, following)
    }
  end

  # RFC 3339 UTC with exactly 3 fractional digits, truncated.
  def timestamp(%DateTime{} = dt), do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
