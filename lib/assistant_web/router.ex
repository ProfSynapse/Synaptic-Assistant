# lib/assistant_web/router.ex — Phoenix router for webhook and OAuth endpoints.
#
# Routes include JSON API endpoints for webhooks and browser-facing HTML
# endpoints for the OAuth2 authorization flow (magic link start + callback).
# Webhook routes will be added as channel adapters are implemented.


defmodule AssistantWeb.Router do
  use AssistantWeb, :router

  import AssistantWeb.SettingsUserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AssistantWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_settings_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Browser-like pipeline without CSRF protection.
  # Used for per-user OAuth flows where requests originate from external sources
  # (magic link clicks from chat, Google OAuth redirects) — no CSRF token available.
  # Security is provided by single-use magic link tokens, PKCE, and HMAC-signed state.
  pipeline :oauth_browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  pipeline :google_chat_auth do
    plug AssistantWeb.Plugs.GoogleChatAuth
  end

  # Per-user Google OAuth flow (magic link → Google consent → callback)
  # No CSRF protection: /start is from a magic link, /callback is from Google redirect.
  scope "/auth/google", AssistantWeb do
    pipe_through :oauth_browser

    get "/start", OAuthController, :start
    get "/callback", OAuthController, :callback
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

  ## Authentication routes

  scope "/", AssistantWeb do
    pipe_through [:browser, :require_authenticated_settings_user]

    live_session :require_authenticated_settings_user,
      on_mount: [{AssistantWeb.SettingsUserAuth, :require_authenticated}] do
      live "/", SettingsLive, :profile
      live "/settings", SettingsLive, :profile
      live "/settings/workflows/:name/edit", WorkflowEditorLive, :edit
      live "/settings/:section", SettingsLive, :section

      live "/settings_users/settings", SettingsUserLive.Settings, :edit

      live "/settings_users/settings/confirm-email/:token",
           SettingsUserLive.Settings,
           :confirm_email
    end

    post "/settings_users/update-password", SettingsUserSessionController, :update_password
  end

  scope "/", AssistantWeb do
    pipe_through [:browser]

    get "/settings_users/auth/google", SettingsUserOAuthController, :request
    get "/settings_users/auth/google/callback", SettingsUserOAuthController, :callback

    live_session :current_settings_user,
      on_mount: [{AssistantWeb.SettingsUserAuth, :mount_current_scope}] do
      live "/settings_users/register", SettingsUserLive.Registration, :new
      live "/settings_users/log-in", SettingsUserLive.Login, :new
      live "/settings_users/magic-link", SettingsUserLive.Login, :magic
      live "/settings_users/log-in/:token", SettingsUserLive.Confirmation, :new
    end

    post "/settings_users/log-in", SettingsUserSessionController, :create
    delete "/settings_users/log-out", SettingsUserSessionController, :delete
  end

  if Application.compile_env(:assistant, :dev_routes, false) do
    scope "/dev" do
      pipe_through :browser

      get "/quick-login", AssistantWeb.SettingsUserDevController, :quick_login
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
