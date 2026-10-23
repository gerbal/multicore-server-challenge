defmodule ConduitWeb.CommentController do
  use ConduitWeb, :controller

  def index(conn, %{"slug" => slug}) do
    case Repo.one_row(SQL.article_id_by_slug(), [slug]) do
      nil ->
        {:error, 404, "article not found"}

      [article_id] ->
        rows = Repo.all_rows(SQL.comments(), [conn.assigns.viewer, article_id])
        reply(conn, 200, %{comments: Enum.map(rows, &comment/1)})
    end
  end

  def create(conn, %{"slug" => slug}) do
    with {:ok, fields, conn} <- Body.fetch(conn, "comment"),
         {:ok, body} <- Body.required(fields, "body") do
      case Repo.one_row(SQL.article_id_by_slug(), [slug]) do
        nil ->
          {:error, 404, "article not found"}

        [article_id] ->
          row = Repo.one_row(SQL.insert_comment(), [article_id, conn.assigns.viewer, body])
          reply(conn, 201, %{comment: comment(row ++ [false])})
      end
    end
  end

  def delete(conn, %{"slug" => slug, "id" => id}) do
    with {:ok, id} <- parse_id(id) do
      case Repo.one_row(SQL.comment_owner(), [id, slug]) do
        nil ->
          {:error, 404, "comment not found"}

        [author_id] when author_id != conn.assigns.viewer ->
          {:error, 403, "not your comment"}

        [_] ->
          Repo.query!(SQL.delete_comment(), [id])
          no_content(conn)
      end
    end
  end

  # Only plain digits that fit in a bigint; anything else is no such comment.
  defp parse_id(id) do
    with true <- id =~ ~r/\A[0-9]{1,18}\z/, {n, ""} <- Integer.parse(id) do
      {:ok, n}
    else
      _ -> {:error, 404, "comment not found"}
    end
  end
end
