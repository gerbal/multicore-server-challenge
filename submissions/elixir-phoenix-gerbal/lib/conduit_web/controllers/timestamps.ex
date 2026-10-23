defmodule ConduitWeb.Timestamps do
  @moduledoc false

  @doc "RFC 3339 in UTC with exactly three fractional digits, truncated: `2025-04-01T12:00:00.000Z`."
  def format(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
