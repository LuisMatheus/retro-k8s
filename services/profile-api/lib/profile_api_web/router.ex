defmodule ProfileApiWeb.Router do
  use ProfileApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ProfileApiWeb do
    pipe_through :api

    get "/profiles", ProfileController, :index
    post "/profiles", ProfileController, :create
    patch "/profiles/:id", ProfileController, :update
  end
end
