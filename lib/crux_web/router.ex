defmodule CruxWeb.Router do
  use CruxWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CruxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CruxWeb do
    pipe_through :browser

    live "/", AnalyzeLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", CruxWeb do
  #   pipe_through :api
  # end
end
