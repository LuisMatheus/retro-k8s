defmodule ProfileApi.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :display_name, :string, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
