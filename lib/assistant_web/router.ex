# lib/assistant_web/router.ex — Phoenix router for webhook endpoints.
#
# All routes are JSON API endpoints. No browser pipeline.
# Webhook routes will be added as channel adapters are implemented.

defmodule AssistantWeb.Router do
  use AssistantWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :google_chat_auth do
    plug AssistantWeb.Plugs.GoogleChatAuth
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

  # Dev routes can be added here when needed (e.g., debug endpoints)
  # This is a webhooks-only application — no browser/HTML routes.
end
