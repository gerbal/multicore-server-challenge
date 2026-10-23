defmodule Conduit.Repo do
  use Ecto.Repo, otp_app: :conduit, adapter: Ecto.Adapters.Postgres

  @doc "All rows of a raw SQL query."
  def all_rows(sql, params), do: query!(sql, params).rows

  @doc "The first row of a raw SQL query, or nil."
  def one_row(sql, params), do: sql |> all_rows(params) |> List.first()

  @doc "Like `one_row/2`, but a unique violation (SQLSTATE 23505) is `{:error, :unique}`."
  def insert_row(sql, params) do
    case query(sql, params) do
      {:ok, %{rows: [row | _]}} -> {:ok, row}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> {:error, :unique}
      {:error, err} -> raise err
    end
  end
end
