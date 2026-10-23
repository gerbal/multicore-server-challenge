defmodule ConduitWeb.Body do
  @moduledoc """
  Request bodies: `{"<wrapper>": {...}}`. Field matching is case-sensitive and unknown fields are ignored.
  Anything that isn't that shape (malformed JSON, empty body, missing or non-object wrapper) is `:error`, i.e. 422.
  """

  def fetch(conn, wrapper) do
    with {:ok, raw, conn} <- Plug.Conn.read_body(conn, length: 1_000_000),
         {:ok, %{^wrapper => %{} = fields}} <- Jason.decode(raw) do
      {:ok, fields, conn}
    else
      _ -> :error
    end
  end

  @doc "Must be present and a non-empty string."
  def required(fields, key) do
    case Map.get(fields, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> :error
    end
  end

  @doc "Absent or null is nil; otherwise a string (non-empty if `non_empty`)."
  def optional(fields, key, non_empty \\ true) do
    case Map.get(fields, key) do
      nil -> {:ok, nil}
      "" when non_empty -> :error
      s when is_binary(s) -> {:ok, s}
      _ -> :error
    end
  end
end
