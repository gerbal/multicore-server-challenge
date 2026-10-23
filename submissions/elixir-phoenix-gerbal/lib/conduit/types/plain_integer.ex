defmodule Conduit.Types.PlainInteger do
  @moduledoc """
  A non-negative integer that casts only from plain decimal digits that fit in a bigint.

  Ecto's `:integer` also accepts strings like `"+5"`; query parameters here must be digits and nothing else.
  """
  use Ecto.Type

  @max 9_223_372_036_854_775_807

  @impl Ecto.Type
  def type, do: :integer

  @impl Ecto.Type
  def cast(value) when is_integer(value) and value in 0..@max, do: {:ok, value}

  def cast(value) when is_binary(value) do
    if value =~ ~r/\A[0-9]{1,19}\z/ and String.to_integer(value) <= @max,
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  def cast(_value), do: :error

  @impl Ecto.Type
  def load(value), do: {:ok, value}

  @impl Ecto.Type
  def dump(value) when is_integer(value), do: {:ok, value}
  def dump(_value), do: :error
end
