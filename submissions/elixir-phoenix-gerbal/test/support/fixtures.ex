defmodule Conduit.Fixtures do
  @moduledoc "Builds users and articles through the public context functions."

  alias Conduit.{Accounts, Blog}

  def unique_username, do: "user#{System.unique_integer([:positive])}"

  def user_fixture(attrs \\ %{}) do
    username = unique_username()

    {:ok, user} =
      attrs
      |> Enum.into(%{"username" => username, "email" => "#{username}@example.com", "password" => "password123"})
      |> Accounts.register_user()

    user
  end

  def article_fixture(author, attrs \\ %{}) do
    {:ok, article} =
      Blog.create_article(
        author.id,
        Enum.into(attrs, %{"title" => "A title", "description" => "About it", "body" => "The body"})
      )

    article
  end
end
