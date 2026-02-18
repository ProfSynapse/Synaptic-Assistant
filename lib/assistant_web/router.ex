# lib/assistant_web/router.ex — Phoenix router for webhook endpoints.
#
# All routes are JSON API endpoints. No browser pipeline.
# Webhook routes will be added as channel adapters are implemented.

defmodule AssistantWeb.Router do
  use AssistantWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check — used by Railway and monitoring
  scope "/", AssistantWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Webhook endpoints — channel adapters
  scope "/webhooks", AssistantWeb do
    pipe_through :api

    post "/telegram", WebhookController, :telegram
    post "/google-chat", GoogleChatController, :event
  end

  # Dev routes can be added here when needed (e.g., debug endpoints)
  # This is a webhooks-only application — no browser/HTML routes.
end
