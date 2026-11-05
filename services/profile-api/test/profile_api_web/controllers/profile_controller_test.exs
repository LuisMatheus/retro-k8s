defmodule ProfileApiWeb.ProfileControllerTest do
  use ProfileApiWeb.ConnCase

  test "creates, lists, and renames a profile while retaining its ID", %{conn: conn} do
    created = conn |> post("/api/profiles", %{display_name: " Alice "}) |> json_response(201)
    assert created["display_name"] == "Alice"
    assert {:ok, _} = Ecto.UUID.cast(created["id"])
    assert created["created_at"]

    listed = build_conn() |> get("/api/profiles") |> json_response(200)
    assert listed["profiles"] == [created]

    renamed =
      build_conn()
      |> patch("/api/profiles/#{created["id"]}", %{display_name: "Alice 2"})
      |> json_response(200)

    assert renamed["id"] == created["id"]
    assert renamed["created_at"] == created["created_at"]
    assert renamed["display_name"] == "Alice 2"
  end

  test "rejects blank and overly long names", %{conn: conn} do
    assert %{"errors" => %{"display_name" => _}} =
             conn |> post("/api/profiles", %{display_name: "   "}) |> json_response(422)

    assert %{"errors" => %{"display_name" => _}} =
             build_conn()
             |> post("/api/profiles", %{display_name: String.duplicate("a", 51)})
             |> json_response(422)
  end

  test "returns 404 for invalid and missing profile IDs", %{conn: conn} do
    assert %{"error" => "profile not found"} =
             conn
             |> patch("/api/profiles/not-a-uuid", %{display_name: "Alice"})
             |> json_response(404)

    assert %{"error" => "profile not found"} =
             build_conn()
             |> patch("/api/profiles/#{Ecto.UUID.generate()}", %{display_name: "Alice"})
             |> json_response(404)
  end
end
