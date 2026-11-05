defmodule ProfileApi.Profiles do
  @moduledoc "Profile records organize player data; they do not authenticate users."
  import Ecto.Query
  alias ProfileApi.Profiles.Profile
  alias ProfileApi.Repo

  def list_profiles do
    Repo.all(from p in Profile, order_by: [asc: p.inserted_at, asc: p.id])
  end

  def create_profile(attrs), do: %Profile{} |> Profile.changeset(attrs) |> Repo.insert()

  def rename_profile(id, attrs) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Profile{} = profile <- Repo.get(Profile, id) do
      profile |> Profile.changeset(attrs) |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end
end
