defmodule ConduitWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :conduit

  # Request bodies are read and decoded by ConduitWeb.Body, so a malformed body gives 422 instead of 400.
  plug ConduitWeb.Router
end
