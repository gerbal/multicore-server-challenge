defmodule ConduitWeb.UserController do
  use ConduitWeb, :controller

  # bcrypt only looks at the first 72 bytes, so longer passwords are rejected rather than silently truncated.
  @max_password_bytes 72

  def register(conn, _params) do
    with {:ok, fields, conn} <- Body.fetch(conn, "user"),
         {:ok, username} <- Body.required(fields, "username"),
         {:ok, email} <- Body.required(fields, "email"),
         {:ok, password} <- Body.required(fields, "password"),
         {:ok, hash} <- hash_password(password) do
      case Repo.insert_row(SQL.insert_user(), [username, email, hash]) do
        {:ok, [id | _] = row} -> reply(conn, 201, %{user: user(row, Conduit.Token.issue(id))})
        {:error, :unique} -> {:error, 422, "username or email is already taken"}
      end
    end
  end

  def login(conn, _params) do
    with {:ok, fields, conn} <- Body.fetch(conn, "user"),
         {:ok, email} <- Body.required(fields, "email"),
         {:ok, password} <- Body.required(fields, "password") do
      case Repo.one_row(SQL.user_by_email(), [email]) do
        [id, username, email, bio, image, hash] ->
          if Bcrypt.verify_pass(password, hash),
            do: reply(conn, 200, %{user: user([id, username, email, bio, image], Conduit.Token.issue(id))}),
            else: {:error, 401, "invalid email or password"}

        nil ->
          Bcrypt.no_user_verify()
          {:error, 401, "invalid email or password"}
      end
    end
  end

  def show(conn, _params) do
    case Repo.one_row(SQL.user_by_id(), [conn.assigns.viewer]) do
      nil -> {:error, 401, "unauthorized"}
      row -> reply(conn, 200, %{user: user(row, conn.assigns.token)})
    end
  end

  def update(conn, _params) do
    with {:ok, fields, conn} <- Body.fetch(conn, "user"),
         {:ok, email} <- Body.optional(fields, "email"),
         {:ok, username} <- Body.optional(fields, "username"),
         {:ok, password} <- Body.optional(fields, "password"),
         {:ok, bio} <- Body.optional(fields, "bio", false),
         {:ok, image} <- Body.optional(fields, "image", false),
         {:ok, hash} <- if(password, do: hash_password(password), else: {:ok, nil}) do
      case Repo.insert_row(SQL.update_user(), [conn.assigns.viewer, email, username, hash, bio, image]) do
        {:ok, nil} -> {:error, 401, "unauthorized"}
        {:ok, row} -> reply(conn, 200, %{user: user(row, conn.assigns.token)})
        {:error, :unique} -> {:error, 422, "username or email is already taken"}
      end
    end
  end

  defp hash_password(password) when byte_size(password) > @max_password_bytes,
    do: {:error, 422, "password is too long"}

  defp hash_password(password), do: {:ok, Bcrypt.hash_pwd_salt(password)}
end
