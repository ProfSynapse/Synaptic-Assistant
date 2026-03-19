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

  pipeline :telegram_auth do
    plug AssistantWeb.Plugs.TelegramAuth
  end

  pipeline :slack_auth do
    plug AssistantWeb.Plugs.SlackAuth
  end

  pipeline :discord_auth do
    plug AssistantWeb.Plugs.DiscordAuth
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

  # Telegram webhook — secret token verified via TelegramAuth plug
  scope "/webhooks", AssistantWeb do
    pipe_through [:api, :telegram_auth]

    post "/telegram", TelegramController, :webhook
  end

  # Slack webhook — HMAC-SHA256 signature verified via SlackAuth plug
  scope "/webhooks", AssistantWeb do
    pipe_through [:api, :slack_auth]

    post "/slack", SlackController, :event
  end

  # Discord webhook — Ed25519 signature verified via DiscordAuth plug
  scope "/webhooks", AssistantWeb do
    pipe_through [:api, :discord_auth]

    post "/discord", DiscordController, :interaction
  end

  ## Authentication routes

  scope "/", AssistantWeb do
    pipe_through [:browser, :require_authenticated_settings_user]

    get "/settings_users/auth/openai", OpenAIOAuthController, :request
    get "/settings_users/auth/openai/callback", OpenAIOAuthController, :callback
    get "/auth/callback", OpenAIOAuthController, :callback
    get "/settings_users/auth/openai/device/poll", OpenAIOAuthController, :device_poll

    live_session :require_authenticated_settings_user,
      on_mount: [{AssistantWeb.SettingsUserAuth, :require_authenticated}] do
      live "/", SettingsLive, :profile
      live "/workspace", WorkspaceLive, :index
      live "/settings", SettingsLive, :profile
      live "/settings/workflows/:name/edit", WorkflowEditorLive, :edit
      live "/settings/apps/:app_id", SettingsLive, :app_detail
      live "/settings/admin/integrations/:integration_group", SettingsLive, :admin_integration
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

    get "/settings_users/auth/openrouter", OpenRouterOAuthController, :request
    get "/settings_users/auth/openrouter/callback", OpenRouterOAuthController, :callback

    live_session :current_settings_user,
      on_mount: [{AssistantWeb.SettingsUserAuth, :mount_current_scope}] do
      live "/cloud", MarketingLive, :index
      live "/setup", SettingsUserLive.Setup, :index
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
