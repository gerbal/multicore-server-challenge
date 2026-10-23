defmodule ConduitWeb.ArticleController do
  use ConduitWeb, :controller

  # Only the first of these filters that is present and non-empty applies.
  @filters ["tag", "author", "favorited"]

  def index(conn, params) do
    with {:ok, limit, offset} <- page(params) do
      filter =
        Enum.find_value(@filters, fn key ->
          case params[key] do
            v when is_binary(v) and v != "" -> {key, v}
            _ -> nil
          end
        end)

      {page_sql, count_sql} = SQL.list(filter)

      {rows, [[count]]} =
        case filter do
          nil ->
            {Repo.all_rows(page_sql, [conn.assigns.viewer, limit, offset]), Repo.all_rows(count_sql, [])}

          {_, value} ->
            {Repo.all_rows(page_sql, [conn.assigns.viewer, limit, offset, value]), Repo.all_rows(count_sql, [value])}
        end

      reply(conn, 200, %{articles: Enum.map(rows, &article/1), articlesCount: count})
    end
  end

  def feed(conn, params) do
    viewer = conn.assigns.viewer

    with {:ok, limit, offset} <- page(params) do
      rows = Repo.all_rows(SQL.feed(), [viewer, limit, offset])
      [[count]] = Repo.all_rows(SQL.feed_count(), [viewer])
      reply(conn, 200, %{articles: Enum.map(rows, &article/1), articlesCount: count})
    end
  end

  def show(conn, %{"slug" => slug}) do
    case Repo.one_row(SQL.article_by_slug(), [conn.assigns.viewer, slug]) do
      nil -> {:error, 404, "article not found"}
      row -> reply(conn, 200, %{article: article(row)})
    end
  end

  def create(conn, _params) do
    viewer = conn.assigns.viewer

    with {:ok, fields, conn} <- Body.fetch(conn, "article"),
         {:ok, title} <- Body.required(fields, "title"),
         {:ok, description} <- Body.required(fields, "description"),
         {:ok, body} <- Body.required(fields, "body"),
         {:ok, tags} <- tag_list(fields) do
      {:ok, id} =
        Repo.transaction(fn ->
          [id] = Repo.one_row(SQL.insert_article(), [viewer, title, description, body])

          if tags != [] do
            Repo.query!(SQL.insert_tags(), [tags])
            Repo.query!(SQL.insert_article_tags(), [id, tags])
          end

          id
        end)

      reply(conn, 201, %{article: article(Repo.one_row(SQL.article_by_id(), [viewer, id]))})
    end
  end

  def update(conn, %{"slug" => slug}) do
    viewer = conn.assigns.viewer

    with {:ok, fields, conn} <- Body.fetch(conn, "article"),
         {:ok, title} <- Body.optional(fields, "title"),
         {:ok, description} <- Body.optional(fields, "description"),
         {:ok, body} <- Body.optional(fields, "body"),
         {:ok, id} <- own_article(slug, viewer) do
      Repo.query!(SQL.update_article(), [id, title, description, body])
      reply(conn, 200, %{article: article(Repo.one_row(SQL.article_by_id(), [viewer, id]))})
    end
  end

  def delete(conn, %{"slug" => slug}) do
    with {:ok, id} <- own_article(slug, conn.assigns.viewer) do
      Repo.query!(SQL.delete_article(), [id])
      no_content(conn)
    end
  end

  def favorite(conn, params), do: toggle_favorite(conn, params, SQL.favorite())
  def unfavorite(conn, params), do: toggle_favorite(conn, params, SQL.unfavorite())

  defp toggle_favorite(conn, %{"slug" => slug}, sql) do
    viewer = conn.assigns.viewer

    case Repo.one_row(SQL.article_id_by_slug(), [slug]) do
      nil ->
        {:error, 404, "article not found"}

      [id] ->
        Repo.query!(sql, [viewer, id])
        reply(conn, 200, %{article: article(Repo.one_row(SQL.article_by_id(), [viewer, id]))})
    end
  end

  defp own_article(slug, viewer) do
    case Repo.one_row(SQL.article_owner(), [slug]) do
      nil -> {:error, 404, "article not found"}
      [id, ^viewer] -> {:ok, id}
      [_, _] -> {:error, 403, "not your article"}
    end
  end

  # Optional; if present (and not null), an array of non-empty strings.
  defp tag_list(fields) do
    case Map.get(fields, "tagList") do
      nil -> {:ok, []}
      tags when is_list(tags) -> if Enum.all?(tags, &(is_binary(&1) and &1 != "")), do: {:ok, tags}, else: :error
      _ -> :error
    end
  end

  # limit: default 20, 1..100; offset: default 0, >= 0. Present means it must be a valid integer.
  defp page(params) do
    with {:ok, limit} <- int_param(params, "limit", 20),
         {:ok, offset} <- int_param(params, "offset", 0),
         true <- limit in 1..100 do
      {:ok, limit, offset}
    else
      _ -> {:error, 422, "limit must be 1-100 and offset >= 0"}
    end
  end

  defp int_param(params, key, default) do
    case Map.fetch(params, key) do
      :error -> {:ok, default}
      {:ok, v} when is_binary(v) -> if v =~ ~r/\A[0-9]{1,9}\z/, do: {:ok, String.to_integer(v)}, else: :error
      _ -> :error
    end
  end
end
