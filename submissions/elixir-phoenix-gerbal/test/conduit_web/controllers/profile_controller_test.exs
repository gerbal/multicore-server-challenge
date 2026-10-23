defmodule ConduitWeb.ProfileControllerTest do
  use ConduitWeb.ConnCase, async: true

  test "shows, follows and unfollows", %{conn: conn} do
    celeb = user_fixture()
    fan = authenticate(conn, user_fixture())

    assert %{"profile" => %{"username" => username, "following" => false, "bio" => nil}} =
             conn |> get(~p"/api/profiles/#{celeb.username}") |> json_response(200)

    assert username == celeb.username

    assert %{"profile" => %{"following" => true}} =
             fan |> post(~p"/api/profiles/#{celeb.username}/follow") |> json_response(200)

    assert %{"profile" => %{"following" => true}} =
             fan |> get(~p"/api/profiles/#{celeb.username}") |> json_response(200)

    assert %{"profile" => %{"following" => false}} =
             fan |> delete(~p"/api/profiles/#{celeb.username}/follow") |> json_response(200)
  end

  test "unknown users are a 404", %{conn: conn} do
    assert conn |> get(~p"/api/profiles/nobody-here") |> json_response(404)
  end

  test "an invalid token is a 401 even where auth is optional", %{conn: conn} do
    celeb = user_fixture()
    conn = conn |> put_req_header("authorization", "Token not-a-jwt") |> get(~p"/api/profiles/#{celeb.username}")
    assert json_response(conn, 401)
  end
end
