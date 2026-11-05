defmodule ProfileApi.Repo do
  use Ecto.Repo,
    otp_app: :profile_api,
    adapter: Ecto.Adapters.SQLite3
end
