defmodule Conduit.Blog.Tag do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "tags" do
    field :name, :string
  end
end
