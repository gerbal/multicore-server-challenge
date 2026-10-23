defmodule ConduitWeb.TagControllerTest do
  use ConduitWeb.ConnCase, async: true

  test "lists tags sorted by name", %{conn: conn} do
    article_fixture(user_fixture(), %{"tag_list" => ["zeta", "alpha"]})
    assert %{"tags" => ["alpha", "zeta"]} = conn |> get(~p"/api/tags") |> json_response(200)
  end
end
