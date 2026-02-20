# lib/assistant_web/router.ex — Phoenix router for webhook and OAuth endpoints.
#
# Routes include JSON API endpoints for webhooks and browser-facing HTML
# endpoints for the OAuth2 authorization flow (magic link start + callback).
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

  # OAuth2 browser flow — magic link start + Google callback.
  # These routes serve HTML (not JSON) and are outside any auth pipeline.
  # Security is enforced by magic link validation (start) and HMAC state (callback).
  scope "/auth/google", AssistantWeb do
    get "/start", OAuthController, :start
    get "/callback", OAuthController, :callback
  end
end
