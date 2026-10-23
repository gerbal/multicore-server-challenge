defmodule Conduit.Token do
  @moduledoc "HS256 JWTs: `{sub, iat, exp}`, valid for 30 days. Verified on every request, nothing remembered."

  @ttl 30 * 24 * 3600

  defp signer, do: Joken.Signer.create("HS256", Application.fetch_env!(:conduit, :jwt_secret))

  def issue(user_id) do
    now = System.system_time(:second)
    Joken.generate_and_sign!(%{}, %{"sub" => Integer.to_string(user_id), "iat" => now, "exp" => now + @ttl}, signer())
  end

  @doc "Returns `{:ok, user_id}` for a validly signed, unexpired HS256 token with a decimal `sub`, else `:error`."
  def verify(token) do
    # Joken.Signer verifies strictly against the signer's algorithm, so `alg: none` or any other alg fails here.
    with {:ok, %{"sub" => sub, "exp" => exp}} when is_binary(sub) and is_integer(exp) <- Joken.verify(token, signer()),
         true <- exp > System.system_time(:second),
         true <- sub =~ ~r/\A[0-9]+\z/,
         {id, ""} when id > 0 <- Integer.parse(sub) do
      {:ok, id}
    else
      _ -> :error
    end
  end
end
