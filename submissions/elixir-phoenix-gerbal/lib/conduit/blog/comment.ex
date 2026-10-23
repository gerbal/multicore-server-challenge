defmodule Conduit.Blog.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Conduit.Accounts.User
  alias Conduit.Blog.Article

  @type t :: %__MODULE__{}

  schema "comments" do
    field :body, :string

    belongs_to :article, Article
    belongs_to :author, User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body])
    |> validate_required([:body])
  end
end
