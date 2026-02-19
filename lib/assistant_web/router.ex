defmodule AssistantWeb.Router do
  use AssistantWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AssistantWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :google_chat_auth do
    plug AssistantWeb.Plugs.GoogleChatAuth
  end

  # Settings UI (LiveView)
  scope "/", AssistantWeb do
    pipe_through :browser

    live_session :settings do
      live "/", SettingsLive, :general
      live "/settings", SettingsLive, :general
      live "/settings/workflows/:name/edit", WorkflowEditorLive, :edit
      live "/settings/:section", SettingsLive, :section
    end
  end

  # Health check — used by Railway and monitoring
  scope "/", AssistantWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Google Chat webhook — JWT-verified via GoogleChatAuth plug
  scope "/webhooks", AssistantWeb do
    pipe_through [:api, :google_chat_auth]

    post "/google-chat", GoogleChatController, :event
  end

  # Other webhook endpoints — channel adapters (no additional auth yet)
  scope "/webhooks", AssistantWeb do
    pipe_through :api

    post "/telegram", WebhookController, :telegram
  end
end
