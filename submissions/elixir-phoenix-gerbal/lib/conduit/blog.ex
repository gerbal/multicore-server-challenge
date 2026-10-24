defmodule Conduit.Blog do
  @moduledoc """
  Articles, the personal feed, favorites, comments and tags.

  Functions that return articles or comments take the viewer's id (nil when anonymous) to fill in `favorited` and
  the author's `following`.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Conduit.Blog.{Article, Comment, Favorite, Tag}
  alias Conduit.Profiles
  alias Conduit.Profiles.Follow
  alias Conduit.Repo
  alias Conduit.Types.PlainInteger

  # articlesCount stops counting here: an exact total of a big list costs a scan, and the UI only pages through it.
  @count_cap 1000
  @max_comments 100

  # Lists leave out the body, which only a single article shows, and authors leave out email and password hash.
  @summary_fields [:id, :slug, :title, :description, :author_id, :created_at, :updated_at]
  @article_fields [:body | @summary_fields]
  @author_fields [:id, :username, :bio, :image]

  ## Article lists

  @doc """
  Lists articles newest first, with the total count (capped at #{@count_cap}).

  `params` takes `limit` (1..100, default 20), `offset` (default 0) and one of the filters `tag`, `author` and
  `favorited` (the first non-empty one applies). Invalid paging is `{:error, changeset}`.
  """
  @spec list_articles(map(), pos_integer() | nil) ::
          {:ok, %{articles: [Article.t()], count: non_neg_integer()}} | {:error, Ecto.Changeset.t()}
  def list_articles(params, viewer_id) do
    with {:ok, opts} <- list_options(params) do
      query = opts |> filter() |> filter_query()
      {:ok, %{articles: list_page(query, opts, viewer_id), count: capped_count(query)}}
    end
  end

  @doc "Lists the newest articles by authors `viewer_id` follows, with the same paging as `list_articles/2`."
  @spec feed(map(), pos_integer()) ::
          {:ok, %{articles: [Article.t()], count: non_neg_integer()}} | {:error, Ecto.Changeset.t()}
  def feed(params, viewer_id) do
    with {:ok, %{limit: limit, offset: offset}} <- list_options(params) do
      # Each followed author's newest `limit + offset` articles are enough to fill the page, so the newest page is
      # merged from short index walks instead of sorting everything the followed authors ever wrote.
      latest_by_author =
        from a in Article,
          where: a.author_id == parent_as(:follow).followee_id,
          order_by: [desc: a.id],
          limit: ^(limit + offset),
          select: %{id: a.id}

      page_ids =
        from f in Follow,
          as: :follow,
          where: f.follower_id == ^viewer_id,
          inner_lateral_join: a in subquery(latest_by_author),
          on: true,
          order_by: [desc: a.id],
          limit: ^limit,
          offset: ^offset,
          select: a.id

      followees = from f in Follow, where: f.follower_id == ^viewer_id, select: f.followee_id
      count = capped_count(from a in Article, where: a.author_id in subquery(followees))

      {:ok, %{articles: load_page(page_ids, viewer_id), count: count}}
    end
  end

  defp list_options(params) do
    types = %{limit: PlainInteger, offset: PlainInteger, tag: :string, author: :string, favorited: :string}

    # Present-but-empty `limit` or `offset` is invalid, so nothing counts as empty while casting.
    {%{limit: 20, offset: 0}, types}
    |> cast(params, Map.keys(types), empty_values: [])
    |> validate_number(:limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    # The feed limits each followed author to `limit + offset` articles, which must fit in a bigint.
    |> validate_number(:offset, less_than_or_equal_to: 2 ** 63 - 101)
    |> apply_action(:list)
  end

  defp filter(opts) do
    Enum.find_value([:tag, :author, :favorited], fn key ->
      case opts do
        %{^key => value} when value != "" -> {key, value}
        _ -> nil
      end
    end)
  end

  defp filter_query(nil), do: Article

  defp filter_query({:tag, name}) do
    from a in Article, join: t in assoc(a, :tags), where: t.name == ^name
  end

  defp filter_query({:author, username}) do
    from a in Article, join: u in assoc(a, :author), where: u.username == ^username
  end

  defp filter_query({:favorited, username}) do
    from a in Article,
      join: f in Favorite,
      on: f.article_id == a.id,
      join: u in assoc(f, :user),
      where: u.username == ^username
  end

  defp list_page(query, %{limit: limit, offset: offset}, viewer_id) do
    query
    |> order_by([a], desc: a.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([a], a.id)
    |> load_page(viewer_id)
  end

  # Lists pick a page of ids first and then load just those articles, so the per-article subqueries for counts and
  # the viewer run for the page only.
  defp load_page(page_ids, viewer_id) do
    query = articles_query(viewer_id, @summary_fields)
    Repo.all(from a in query, where: a.id in subquery(page_ids), order_by: [desc: a.id])
  end

  defp capped_count(query) do
    query
    |> select([a], %{id: a.id})
    |> limit(@count_cap)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  # Articles with their author, tag names, favorite count, and the viewer's `favorited` and `following`.
  #
  # Tag names are aggregated in the same query rather than preloaded, which would cost a second round trip.
  defp articles_query(viewer_id, fields \\ @article_fields) do
    favorites = from f in Favorite, where: f.article_id == parent_as(:article).id
    favorited = from f in favorites, where: f.user_id == ^(viewer_id || 0)

    tag_names =
      from t in Tag,
        join: at in "article_tags",
        on: at.tag_id == t.id,
        where: at.article_id == parent_as(:article).id,
        select: fragment("coalesce(array_agg(? ORDER BY ?), '{}')", t.name, t.name)

    from a in Article,
      as: :article,
      join: u in assoc(a, :author),
      as: :author,
      select:
        merge(struct(a, ^fields), %{
          tag_list: subquery(tag_names),
          favorites_count: subquery(from f in favorites, select: count()),
          favorited: exists(subquery(favorited)),
          author: merge(struct(u, @author_fields), %{following: exists(subquery(Profiles.follows_author(viewer_id)))})
        })
  end

  ## Single articles

  @doc "Gets an article by slug."
  @spec get_article(String.t(), pos_integer() | nil) :: {:ok, Article.t()} | {:error, :not_found}
  def get_article(slug, viewer_id) do
    fetch(Repo.one(from a in articles_query(viewer_id), where: a.slug == ^slug))
  end

  defp get_article!(id, viewer_id), do: Repo.one!(from a in articles_query(viewer_id), where: a.id == ^id)

  @doc "Publishes an article by `author_id`, creating any tags that don't exist yet."
  @spec create_article(pos_integer(), map()) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def create_article(author_id, attrs) do
    insert =
      %Article{author_id: author_id}
      |> Article.create_changeset(attrs)
      |> prepare_changes(&put_tags/1)
      |> Repo.insert()

    with {:ok, article} <- insert, do: {:ok, get_article!(article.id, author_id)}
  end

  # Runs inside the insert's transaction. Names are sorted so concurrent upserts take row locks in the same order.
  defp put_tags(changeset) do
    case (get_field(changeset, :tag_list) || []) |> Enum.uniq() |> Enum.sort() do
      [] ->
        put_assoc(changeset, :tags, [])

      names ->
        changeset.repo.insert_all(Tag, Enum.map(names, &%{name: &1}), on_conflict: :nothing, conflict_target: :name)
        put_assoc(changeset, :tags, changeset.repo.all(from t in Tag, where: t.name in ^names))
    end
  end

  @doc "Edits an article. Only its author may."
  @spec update_article(String.t(), pos_integer(), map()) ::
          {:ok, Article.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def update_article(slug, user_id, attrs) do
    with {:ok, article} <- fetch_own_article(slug, user_id),
         # force: an edit always bumps updated_at, even when nothing else changed.
         {:ok, article} <- article |> Article.update_changeset(attrs) |> Repo.update(force: true) do
      {:ok, get_article!(article.id, user_id)}
    end
  end

  @doc "Deletes an article, with its comments, tags links and favorites. Only its author may."
  @spec delete_article(String.t(), pos_integer()) :: :ok | {:error, :not_found | :forbidden}
  def delete_article(slug, user_id) do
    with {:ok, article} <- fetch_own_article(slug, user_id) do
      Repo.delete!(article)
      :ok
    end
  end

  defp fetch_own_article(slug, user_id) do
    with {:ok, article} <- fetch(Repo.get_by(Article, slug: slug)),
         :ok <- authorize(article, user_id),
         do: {:ok, article}
  end

  ## Favorites

  @doc "Favorites an article. Favoriting it twice is fine."
  @spec favorite_article(String.t(), pos_integer()) :: {:ok, Article.t()} | {:error, :not_found}
  def favorite_article(slug, user_id) do
    with {:ok, article_id} <- fetch_article_id(slug) do
      Repo.insert!(%Favorite{user_id: user_id, article_id: article_id}, on_conflict: :nothing)
      {:ok, get_article!(article_id, user_id)}
    end
  end

  @doc "Removes a favorite."
  @spec unfavorite_article(String.t(), pos_integer()) :: {:ok, Article.t()} | {:error, :not_found}
  def unfavorite_article(slug, user_id) do
    with {:ok, article_id} <- fetch_article_id(slug) do
      Repo.delete_all(from f in Favorite, where: f.user_id == ^user_id and f.article_id == ^article_id)
      {:ok, get_article!(article_id, user_id)}
    end
  end

  ## Comments

  @doc "Lists an article's newest #{@max_comments} comments, newest first."
  @spec list_comments(String.t(), pos_integer() | nil) :: {:ok, [Comment.t()]} | {:error, :not_found}
  def list_comments(slug, viewer_id) do
    with {:ok, article_id} <- fetch_article_id(slug) do
      query =
        from c in Comment,
          join: u in assoc(c, :author),
          as: :author,
          where: c.article_id == ^article_id,
          order_by: [desc: c.created_at, desc: c.id],
          limit: @max_comments,
          select:
            merge(c, %{
              author:
                merge(struct(u, @author_fields), %{following: exists(subquery(Profiles.follows_author(viewer_id)))})
            })

      {:ok, Repo.all(query)}
    end
  end

  @doc "Comments on an article as `author_id`."
  @spec create_comment(String.t(), pos_integer(), map()) ::
          {:ok, Comment.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def create_comment(slug, author_id, attrs) do
    changeset = Comment.changeset(%Comment{author_id: author_id}, attrs)

    # A bad body is reported before an unknown article, as for the other writes.
    with :ok <- validate(changeset),
         {:ok, article_id} <- fetch_article_id(slug),
         {:ok, comment} <- changeset |> put_change(:article_id, article_id) |> Repo.insert() do
      # Nobody follows themselves, so the author's `following` keeps its default, false.
      {:ok, Repo.preload(comment, :author)}
    end
  end

  @doc "Deletes a comment on the article `slug`. Only its author may."
  @spec delete_comment(String.t(), String.t(), pos_integer()) :: :ok | {:error, :not_found | :forbidden}
  def delete_comment(slug, comment_id, user_id) do
    with {:ok, id} <- parse_id(comment_id),
         {:ok, comment} <-
           fetch(Repo.one(from c in Comment, join: a in assoc(c, :article), where: c.id == ^id and a.slug == ^slug)),
         :ok <- authorize(comment, user_id) do
      Repo.delete!(comment)
      :ok
    end
  end

  ## Tags

  @doc "All tag names, sorted."
  @spec list_tags() :: [String.t()]
  def list_tags, do: Repo.all(from t in Tag, order_by: t.name, select: t.name)

  ## Helpers

  defp fetch_article_id(slug) do
    fetch(Repo.one(from a in Article, where: a.slug == ^slug, select: a.id))
  end

  # Only a plain decimal that fits in a bigint can be a comment id.
  defp parse_id(id) do
    case Integer.parse(id) do
      {n, ""} when n in 1..9_223_372_036_854_775_807 -> {:ok, n}
      _ -> {:error, :not_found}
    end
  end

  defp validate(%Ecto.Changeset{valid?: true}), do: :ok
  defp validate(changeset), do: {:error, changeset}

  defp authorize(%{author_id: author_id}, user_id) when author_id == user_id, do: :ok
  defp authorize(_resource, _user_id), do: {:error, :forbidden}

  defp fetch(nil), do: {:error, :not_found}
  defp fetch(value), do: {:ok, value}
end
