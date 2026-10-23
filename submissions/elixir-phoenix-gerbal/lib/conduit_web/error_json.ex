defmodule ConduitWeb.ErrorJSON do
  @moduledoc "Errors raised outside the controllers (no route, crashes) in the `errors.body` shape."
  def render(template, _assigns),
    do: %{errors: %{body: [Phoenix.Controller.status_message_from_template(template)]}}
end
