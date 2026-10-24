defmodule Conduit.Blog.Favorite do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  alias Conduit.Accounts.User
  alias Conduit.Blog.Article

  @primary_key false
  schema "favorites" do
    belongs_to :user, User, primary_key: true
    belongs_to :article, Article, primary_key: true
  end

  @doc "A changeset for a new favorite. The article may have been deleted since it was looked up."
  def changeset(%__MODULE__{} = favorite), do: favorite |> change() |> foreign_key_constraint(:article_id)
end
