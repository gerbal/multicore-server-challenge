defmodule ConduitWeb.ProfileController do
  use ConduitWeb, :controller

  def show(conn, %{"username" => username}) do
    case Repo.one_row(SQL.profile(), [conn.assigns.viewer, username]) do
      nil -> {:error, 404, "profile not found"}
      [_id, username, bio, image, following] -> reply(conn, 200, %{profile: profile(username, bio, image, following)})
    end
  end

  def follow(conn, params), do: toggle(conn, params, SQL.follow(), true)
  def unfollow(conn, params), do: toggle(conn, params, SQL.unfollow(), false)

  defp toggle(conn, %{"username" => username}, sql, following) do
    case Repo.one_row(SQL.user_by_username(), [username]) do
      nil ->
        {:error, 404, "profile not found"}

      [id, username, bio, image] ->
        Repo.query!(sql, [conn.assigns.viewer, id])
        reply(conn, 200, %{profile: profile(username, bio, image, following)})
    end
  end
end
