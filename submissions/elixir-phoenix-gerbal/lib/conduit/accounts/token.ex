defmodule Conduit.Accounts.Token do
  @moduledoc """
  HS256 JWTs carrying `sub` (the user id as a decimal string), `iat` and `exp` (30 days later).

  The signer is the `:default_signer` configured in `config/runtime.exs`. Every token is verified on every request;
  nothing is remembered.
  """
  use Joken.Config

  @ttl 30 * 24 * 60 * 60

  @impl Joken.Config
  def token_config do
    [skip: [:aud, :iss, :jti, :nbf], default_exp: @ttl]
    |> default_claims()
    |> add_claim("sub", nil, &(is_binary(&1) and &1 =~ ~r/\A[0-9]{1,18}\z/))
  end

  @doc "Signs a fresh token for `user_id`."
  @spec sign(pos_integer()) :: String.t()
  def sign(user_id) do
    generate_and_sign!(%{"sub" => Integer.to_string(user_id)})
  end

  @doc """
  Returns `{:ok, user_id}` for a token with a valid HS256 signature, an `exp` in the future and a `sub` that is a
  positive decimal user id.

  Joken only validates the claims a token carries, so that `sub` and `exp` are present is checked here.
  """
  @spec fetch_user_id(String.t()) :: {:ok, pos_integer()} | :error
  def fetch_user_id(token) do
    with {:ok, %{"sub" => sub, "exp" => _exp}} <- verify_and_validate(token),
         user_id when user_id > 0 <- String.to_integer(sub) do
      {:ok, user_id}
    else
      _ -> :error
    end
  end
end
