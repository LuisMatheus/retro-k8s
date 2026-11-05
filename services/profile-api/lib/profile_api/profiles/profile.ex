defmodule ProfileApi.Profiles.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "profiles" do
    field :display_name, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: 50)
  end
end
