defmodule ProfileApiWeb.ProfileController do
  use ProfileApiWeb, :controller
  alias ProfileApi.Profiles

  def index(conn, _params),
    do: json(conn, %{profiles: Enum.map(Profiles.list_profiles(), &present/1)})

  def create(conn, params) do
    case Profiles.create_profile(params) do
      {:ok, profile} -> conn |> put_status(:created) |> json(present(profile))
      {:error, changeset} -> invalid(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Profiles.rename_profile(id, params) do
      {:ok, profile} ->
        json(conn, present(profile))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "profile not found"})

      {:error, changeset} ->
        invalid(conn, changeset)
    end
  end

  defp present(profile),
    do: %{id: profile.id, display_name: profile.display_name, created_at: profile.inserted_at}

  defp invalid(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
  end
end
