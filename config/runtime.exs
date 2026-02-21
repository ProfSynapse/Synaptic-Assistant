# config/runtime.exs — Runtime configuration loaded at application boot.
#
# ALL secrets and environment-specific values go here.
# This file is evaluated at runtime (not compile time), making it safe
# for production releases where env vars are injected at deploy time.

import Config

# Load .env file in dev so `mix phx.server` works without manual exports.
# Existing shell env vars take precedence over .env values.
if config_env() == :dev && File.exists?(".env") do
  ".env"
  |> File.read!()
  |> String.split("\n")
  |> Enum.each(fn line ->
    line = String.trim(line)

    with false <- line == "",
         false <- String.starts_with?(line, "#"),
         [key, value] <- String.split(line, "=", parts: 2),
         key = String.trim(key),
         true <- key != "",
         nil <- System.get_env(key) do
      System.put_env(key, value |> String.trim() |> String.trim("\"") |> String.trim("'"))
    end
  end)
end

# Start server if PHX_SERVER is set (used by releases)
if System.get_env("PHX_SERVER") do
  config :assistant, AssistantWeb.Endpoint, server: true
end

# PORT configuration for all environments
config :assistant, AssistantWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :assistant, Assistant.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :assistant, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :assistant, AssistantWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end

# --- API Keys (all environments, optional) ---

# OpenRouter — LLM provider (chat completions, tool calling, STT)
if api_key = System.get_env("OPENROUTER_API_KEY") do
  config :assistant, :openrouter_api_key, api_key
end

# OpenAI — optional direct provider path for per-user model routing.
if api_key = System.get_env("OPENAI_API_KEY") do
  config :assistant, :openai_api_key, api_key
end

# OpenAI OAuth client configuration (for account connect flow)
if client_id = System.get_env("OPENAI_OAUTH_CLIENT_ID") do
  config :assistant, :openai_oauth_client_id, client_id
end

if client_secret = System.get_env("OPENAI_OAUTH_CLIENT_SECRET") do
  config :assistant, :openai_oauth_client_secret, client_secret
end

if authorize_url = System.get_env("OPENAI_OAUTH_AUTHORIZE_URL") do
  config :assistant, :openai_oauth_authorize_url, authorize_url
end

if token_url = System.get_env("OPENAI_OAUTH_TOKEN_URL") do
  config :assistant, :openai_oauth_token_url, token_url
end

if scope = System.get_env("OPENAI_OAUTH_SCOPE") do
  config :assistant, :openai_oauth_scope, scope
end

if codex_compat = System.get_env("OPENAI_OAUTH_CODEX_COMPAT") do
  config :assistant,
         :openai_oauth_codex_compat,
         codex_compat in ["1", "true", "TRUE", "yes", "YES"]
end

if originator = System.get_env("OPENAI_OAUTH_ORIGINATOR") do
  config :assistant, :openai_oauth_originator, originator
end

if redirect_uri = System.get_env("OPENAI_OAUTH_REDIRECT_URI") do
  config :assistant, :openai_oauth_redirect_uri, redirect_uri
end

if oauth_flow = System.get_env("OPENAI_OAUTH_FLOW") do
  config :assistant, :openai_oauth_flow, oauth_flow
end

if oauth_issuer = System.get_env("OPENAI_OAUTH_ISSUER") do
  config :assistant, :openai_oauth_issuer, oauth_issuer
end

# Google service account credentials (inline JSON string or file path to JSON key).
# Now used ONLY for Google Chat bot operations (chat.bot scope).
# Per-user Gmail/Drive/Calendar access uses OAuth2 client credentials below.
if google_creds = System.get_env("GOOGLE_APPLICATION_CREDENTIALS") do
  credentials =
    if String.starts_with?(String.trim(google_creds), "{") do
      Jason.decode!(google_creds)
    else
      google_creds |> File.read!() |> Jason.decode!()
    end

  config :assistant, :google_credentials, credentials
end

# Google OAuth2 client credentials — for per-user authorization flow.
# Obtain from Google Cloud Console > APIs & Services > Credentials > OAuth 2.0 Client ID.
# Required for Gmail, Drive, and Calendar per-user access.
if client_id = System.get_env("GOOGLE_OAUTH_CLIENT_ID") do
  config :assistant, :google_oauth_client_id, client_id
end

if client_secret = System.get_env("GOOGLE_OAUTH_CLIENT_SECRET") do
  config :assistant, :google_oauth_client_secret, client_secret
end

# Google Cloud project number (used for Google Chat JWT audience verification)
if project_number = System.get_env("GOOGLE_CLOUD_PROJECT_NUMBER") do
  config :assistant, :google_cloud_project_number, project_number
end

# ElevenLabs — Text-to-Speech
if api_key = System.get_env("ELEVENLABS_API_KEY") do
  config :assistant, :elevenlabs_api_key, api_key
end

if voice_id = System.get_env("ELEVENLABS_VOICE_ID") do
  config :assistant, :elevenlabs_voice_id, voice_id
end

# Telegram Bot
if token = System.get_env("TELEGRAM_BOT_TOKEN") do
  config :assistant, :telegram_bot_token, token
end

if secret = System.get_env("TELEGRAM_WEBHOOK_SECRET") do
  config :assistant, :telegram_webhook_secret, secret
end

# Google Chat
if webhook_url = System.get_env("GOOGLE_CHAT_WEBHOOK_URL") do
  config :assistant, :google_chat_webhook_url, webhook_url
end

# HubSpot
if api_key = System.get_env("HUBSPOT_API_KEY") do
  config :assistant, :hubspot_api_key, api_key
end

# Cloak encryption key for Ecto field encryption.
# Required in production — OAuth tokens are encrypted at rest via Cloak AES-GCM.
# In dev/test, omitting this env var means the Vault starts with no ciphers
# (encrypted fields will error on read/write, which is acceptable for tests
# that don't exercise token storage).
if config_env() == :prod do
  encryption_key =
    System.get_env("CLOAK_ENCRYPTION_KEY") ||
      raise """
      environment variable CLOAK_ENCRYPTION_KEY is missing.
      Generate a 256-bit key: :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  config :assistant, Assistant.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(encryption_key)
      }
    ]
else
  if encryption_key = System.get_env("CLOAK_ENCRYPTION_KEY") do
    config :assistant, Assistant.Vault,
      ciphers: [
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: Base.decode64!(encryption_key)
        }
      ]
  end
end
