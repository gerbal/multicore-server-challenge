defmodule Conduit.SQL do
  @moduledoc "The reference SQL from SPEC.md, verbatim."

  @article_cols """
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
         ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
    FROM articles a
    JOIN users u ON u.id = a.author_id
  """
  @article_list_select @article_cols
  @article_full_select String.replace(@article_cols, "a.description,", "a.description, a.body,")
  @slugify "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))"
  @order_page "ORDER BY a.id DESC LIMIT $2 OFFSET $3"

  # Users
  def insert_user,
    do:
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"

  def user_by_email, do: "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
  def user_by_id, do: "SELECT id, username, email, bio, image FROM users WHERE id = $1"

  def update_user do
    """
    UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                     password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
     WHERE id = $1
    RETURNING id, username, email, bio, image
    """
  end

  # Profiles
  def profile do
    """
    SELECT u.id, u.username, u.bio, u.image,
           EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
      FROM users u WHERE u.username = $2
    """
  end

  def user_by_username, do: "SELECT id, username, bio, image FROM users WHERE username = $1"
  def follow, do: "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
  def unfollow, do: "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2"

  # Article lists: {page, count}
  def list(nil),
    do: {@article_list_select <> @order_page, "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"}

  def list({"tag", _}) do
    {@article_list_select <>
       "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
     "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"}
  end

  def list({"author", _}) do
    {@article_list_select <> "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) " <> @order_page,
     "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"}
  end

  def list({"favorited", _}) do
    {@article_list_select <>
       "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
     "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"}
  end

  def feed do
    """
    #{@article_list_select}WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
        (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
      WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
    """
  end

  def feed_count,
    do:
      "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"

  # Single articles
  def article_by_slug, do: @article_full_select <> "WHERE a.slug = $2"
  def article_by_id, do: @article_full_select <> "WHERE a.id = $2"

  def insert_article do
    """
    INSERT INTO articles (id, slug, author_id, title, description, body)
    SELECT n.id, #{@slugify} || '-' || n.id, $1, $2, $3, $4
      FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
    RETURNING id
    """
  end

  def insert_tags, do: "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"

  def insert_article_tags,
    do: "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"

  def article_owner, do: "SELECT id, author_id FROM articles WHERE slug = $1"

  def update_article do
    """
    UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
           slug = CASE WHEN $2::text IS NULL THEN slug ELSE #{@slugify} || '-' || id END,
           updated_at = now()
     WHERE id = $1
    """
  end

  def delete_article, do: "DELETE FROM articles WHERE id = $1"

  # Favorites
  def article_id_by_slug, do: "SELECT id FROM articles WHERE slug = $1"
  def favorite, do: "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
  def unfavorite, do: "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2"

  # Comments
  def comments do
    """
    SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
           EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
      FROM comments c JOIN users u ON u.id = c.author_id
     WHERE c.article_id = $2
     ORDER BY c.created_at DESC, c.id DESC
     LIMIT 100
    """
  end

  def insert_comment do
    """
    WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
               RETURNING id, body, created_at, updated_at, author_id)
    SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
      FROM c JOIN users u ON u.id = c.author_id
    """
  end

  def comment_owner do
    """
    SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
     WHERE c.id = $1 AND a.slug = $2
    """
  end

  def delete_comment, do: "DELETE FROM comments WHERE id = $1"

  # Tags
  def tags, do: "SELECT name FROM tags ORDER BY name"
end
