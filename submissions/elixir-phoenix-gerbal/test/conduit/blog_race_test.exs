defmodule Conduit.BlogRaceTest do
  # Not async: the triggers lock their tables until the test's transaction rolls back.
  use Conduit.DataCase, async: false

  alias Conduit.Blog

  # A write that reads a row first can lose a race with a request that deletes it. A trigger, rolled back with the
  # test, makes every write lose: run before `event` on `table`, its `body` deletes the article under a new row (whose
  # insert then breaks the foreign key), or skips the row (as a concurrent delete leaves nothing to change).
  defp lose_race(event, table, body) do
    Repo.query!("CREATE FUNCTION lose_race() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN #{body} END $$")
    Repo.query!("CREATE TRIGGER lose_race BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION lose_race()")
  end

  setup do
    author = user_fixture()
    %{author: author, reader: user_fixture(), article: article_fixture(author)}
  end

  test "favoriting an article deleted meanwhile is a 404", %{reader: reader, article: article} do
    lose_race("INSERT", "favorites", "DELETE FROM articles WHERE id = NEW.article_id; RETURN NEW;")
    assert {:error, :not_found} = Blog.favorite_article(article.slug, reader.id)
  end

  test "commenting on an article deleted meanwhile is a 404", %{reader: reader, article: article} do
    lose_race("INSERT", "comments", "DELETE FROM articles WHERE id = NEW.article_id; RETURN NEW;")
    assert {:error, :not_found} = Blog.create_comment(article.slug, reader.id, %{"body" => "hi"})
  end

  test "editing or deleting an article deleted meanwhile is a 404", %{author: author, article: article} do
    lose_race("UPDATE OR DELETE", "articles", "RETURN NULL;")
    assert {:error, :not_found} = Blog.update_article(article.slug, author.id, %{"title" => "New"})
    assert {:error, :not_found} = Blog.delete_article(article.slug, author.id)
  end

  test "an invalid edit is still a changeset when the row is fine", %{author: author, article: article} do
    lose_race("UPDATE", "articles", "RETURN NULL;")
    assert {:error, %Ecto.Changeset{}} = Blog.update_article(article.slug, author.id, %{"title" => ""})
  end

  test "deleting a comment deleted meanwhile is a 404", %{reader: reader, article: article} do
    {:ok, comment} = Blog.create_comment(article.slug, reader.id, %{"body" => "hi"})
    lose_race("DELETE", "comments", "RETURN NULL;")
    assert {:error, :not_found} = Blog.delete_comment(article.slug, Integer.to_string(comment.id), reader.id)
  end
end
