defmodule Conduit.BlogTest do
  use Conduit.DataCase, async: true

  alias Conduit.{Blog, Profiles}

  setup do
    %{alice: user_fixture(), bob: user_fixture()}
  end

  # The test database starts empty, so lists only see the articles each test creates.
  defp slugs(%{articles: articles}), do: Enum.map(articles, & &1.slug)

  describe "create_article/2" do
    test "assigns a slug from the title and id, and links sorted, deduplicated tags", %{alice: alice} do
      article = article_fixture(alice, %{"title" => "Hello, World!", "tag_list" => ["zeta", "alpha", "zeta"]})

      assert article.slug == "hello-world-#{article.id}"
      assert article.tag_list == ["alpha", "zeta"]
      assert article.author.id == alice.id
      assert %{favorited: false, favorites_count: 0} = article
    end

    test "an article without tags has an empty tag list", %{alice: alice} do
      assert article_fixture(alice).tag_list == []
      assert {:ok, %{articles: [%{tag_list: []}]}} = Blog.list_articles(%{}, nil)
    end

    test "reuses existing tags", %{alice: alice} do
      article_fixture(alice, %{"tag_list" => ["elixir"]})
      article_fixture(alice, %{"tag_list" => ["elixir", "phoenix"]})

      assert Blog.list_tags() == ["elixir", "phoenix"]
    end

    test "returns the changeset for invalid input", %{alice: alice} do
      assert {:error, %Ecto.Changeset{}} = Blog.create_article(alice.id, %{"title" => "t"})
    end
  end

  describe "list_articles/2" do
    setup %{alice: alice, bob: bob} do
      first = article_fixture(alice, %{"tag_list" => ["elixir"]})
      second = article_fixture(bob, %{"tag_list" => ["phoenix"]})
      third = article_fixture(alice, %{"tag_list" => ["elixir", "phoenix"]})
      %{first: first, second: second, third: third}
    end

    test "lists newest first with a count", %{first: first, second: second, third: third} do
      assert {:ok, %{count: 3} = page} = Blog.list_articles(%{}, nil)
      assert slugs(page) == [third.slug, second.slug, first.slug]
    end

    test "pages with limit and offset", %{second: second} do
      assert {:ok, %{count: 3} = page} = Blog.list_articles(%{"limit" => "1", "offset" => "1"}, nil)
      assert slugs(page) == [second.slug]
    end

    test "an offset past the last article is an empty page that still has the count" do
      assert {:ok, %{articles: [], count: 3}} = Blog.list_articles(%{"offset" => "3"}, nil)
      assert {:ok, %{articles: [], count: 2}} = Blog.list_articles(%{"tag" => "phoenix", "offset" => "5"}, nil)
    end

    test "filters by tag, author or favoriting user", %{alice: alice, bob: bob} = ctx do
      {:ok, _} = Blog.favorite_article(ctx.second.slug, alice.id)

      assert {:ok, page} = Blog.list_articles(%{"tag" => "elixir"}, nil)
      assert slugs(page) == [ctx.third.slug, ctx.first.slug]

      assert {:ok, %{count: 1} = page} = Blog.list_articles(%{"author" => bob.username}, nil)
      assert slugs(page) == [ctx.second.slug]

      assert {:ok, page} = Blog.list_articles(%{"favorited" => alice.username}, nil)
      assert slugs(page) == [ctx.second.slug]
    end

    test "applies only the first non-empty filter", %{bob: bob} = ctx do
      assert {:ok, page} = Blog.list_articles(%{"tag" => "elixir", "author" => bob.username}, nil)
      assert slugs(page) == [ctx.third.slug, ctx.first.slug]

      assert {:ok, page} = Blog.list_articles(%{"tag" => "", "author" => bob.username}, nil)
      assert slugs(page) == [ctx.second.slug]
    end

    test "unknown filter values give an empty page" do
      assert {:ok, %{articles: [], count: 0}} = Blog.list_articles(%{"tag" => "nope"}, nil)
      assert {:ok, %{articles: [], count: 0}} = Blog.list_articles(%{"author" => "nobody-here"}, nil)
    end

    test "rejects invalid paging" do
      for params <- [%{"limit" => "0"}, %{"limit" => "101"}, %{"limit" => "+5"}, %{"limit" => ""}, %{"offset" => "-1"}] do
        assert {:error, %Ecto.Changeset{}} = Blog.list_articles(params, nil), inspect(params)
      end
    end

    test "sets favorited and following for the viewer", %{alice: alice, bob: bob} = ctx do
      {:ok, _} = Blog.favorite_article(ctx.second.slug, alice.id)
      {:ok, _} = Profiles.follow(alice.id, bob.username)

      {:ok, %{articles: articles}} = Blog.list_articles(%{}, alice.id)
      second = Enum.find(articles, &(&1.id == ctx.second.id))
      third = Enum.find(articles, &(&1.id == ctx.third.id))

      assert %{favorited: true, favorites_count: 1, author: %{following: true}} = second
      assert %{favorited: false, favorites_count: 0, author: %{following: false}} = third

      {:ok, %{articles: articles}} = Blog.list_articles(%{}, nil)
      assert Enum.all?(articles, &(not &1.favorited and not &1.author.following))
    end
  end

  describe "feed/2" do
    test "lists articles by followed authors, newest first", %{alice: alice, bob: bob} do
      carol = user_fixture()
      old = article_fixture(bob)
      _unfollowed = article_fixture(carol)
      new = article_fixture(bob)
      {:ok, _} = Profiles.follow(alice.id, bob.username)

      assert {:ok, %{count: 2} = page} = Blog.feed(%{}, alice.id)
      assert slugs(page) == [new.slug, old.slug]
      assert {:ok, page} = Blog.feed(%{"limit" => "1", "offset" => "1"}, alice.id)
      assert slugs(page) == [old.slug]
      assert {:ok, %{articles: [], count: 2}} = Blog.feed(%{"offset" => "2"}, alice.id)
    end

    test "is empty when following no one", %{alice: alice, bob: bob} do
      article_fixture(bob)
      assert {:ok, %{articles: [], count: 0}} = Blog.feed(%{}, alice.id)
    end
  end

  describe "update_article/3 and delete_article/2" do
    setup %{alice: alice} do
      %{article: article_fixture(alice, %{"title" => "Old title"})}
    end

    test "a new title gives a new slug", %{alice: alice, article: article} do
      assert {:ok, updated} = Blog.update_article(article.slug, alice.id, %{"title" => "New title", "body" => nil})

      assert updated.slug == "new-title-#{article.id}"
      assert updated.body == article.body
      assert DateTime.compare(updated.updated_at, article.updated_at) == :gt
    end

    test "only the author may edit or delete", %{bob: bob, article: article} do
      assert {:error, :forbidden} = Blog.update_article(article.slug, bob.id, %{"title" => "Mine now"})
      assert {:error, :forbidden} = Blog.delete_article(article.slug, bob.id)
    end

    test "rejects blank fields", %{alice: alice, article: article} do
      assert {:error, %Ecto.Changeset{}} = Blog.update_article(article.slug, alice.id, %{"title" => ""})
    end

    test "deletes", %{alice: alice, article: article} do
      assert :ok = Blog.delete_article(article.slug, alice.id)
      assert {:error, :not_found} = Blog.get_article(article.slug, nil)
      assert {:error, :not_found} = Blog.delete_article(article.slug, alice.id)
    end
  end

  describe "favorites" do
    test "count every user once", %{alice: alice, bob: bob} do
      article = article_fixture(alice)

      assert {:ok, %{favorited: true, favorites_count: 1}} = Blog.favorite_article(article.slug, bob.id)
      assert {:ok, %{favorited: true, favorites_count: 1}} = Blog.favorite_article(article.slug, bob.id)
      assert {:ok, %{favorited: true, favorites_count: 2}} = Blog.favorite_article(article.slug, alice.id)
      assert {:ok, %{favorited: false, favorites_count: 1}} = Blog.unfavorite_article(article.slug, bob.id)
      assert {:error, :not_found} = Blog.favorite_article("no-such-article", bob.id)
    end
  end

  describe "comments" do
    setup %{alice: alice} do
      %{article: article_fixture(alice)}
    end

    test "are listed newest first", %{alice: alice, bob: bob, article: article} do
      {:ok, first} = Blog.create_comment(article.slug, alice.id, %{"body" => "first"})
      {:ok, second} = Blog.create_comment(article.slug, bob.id, %{"body" => "second"})

      assert {:ok, [listed_second, listed_first]} = Blog.list_comments(article.slug, nil)
      assert {listed_second.id, listed_first.id} == {second.id, first.id}
      assert listed_second.author.username == bob.username
    end

    test "require a body, reported before an unknown article", %{alice: alice} do
      assert {:error, %Ecto.Changeset{}} = Blog.create_comment("no-such-article", alice.id, %{"body" => ""})
      assert {:error, :not_found} = Blog.create_comment("no-such-article", alice.id, %{"body" => "hi"})
    end

    test "can only be deleted by their author, on their article", %{alice: alice, bob: bob, article: article} do
      {:ok, comment} = Blog.create_comment(article.slug, bob.id, %{"body" => "hi"})
      id = Integer.to_string(comment.id)

      assert {:error, :forbidden} = Blog.delete_comment(article.slug, id, alice.id)
      assert {:error, :not_found} = Blog.delete_comment(article_fixture(alice).slug, id, bob.id)
      assert {:error, :not_found} = Blog.delete_comment(article.slug, "abc", bob.id)
      assert :ok = Blog.delete_comment(article.slug, id, bob.id)
      assert {:ok, []} = Blog.list_comments(article.slug, nil)
    end
  end
end
