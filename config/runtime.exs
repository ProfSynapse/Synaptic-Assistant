# config/runtime.exs — Runtime configuration loaded at application boot.
#
# ALL secrets and environment-specific values go here.
# This file is evaluated at runtime (not compile time), making it safe
# for production releases where env vars are injected at deploy time.

import Config

parse_bool = fn
  value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
  _ -> false
end

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
    check_origin: [
      "https://#{host}",
      "https://*.railway.app"
    ],
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

# OpenAI OAuth settings (client_id, URLs, scope, flow) use hardcoded defaults
# in OpenaiOauthController. Override via env vars if needed (see controller source).

# Google OAuth2 client credentials — for per-user authorization flow and Chat bot auth.
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

# Google write concurrency rollout flags (Drive/Docs conflict protection)
config :assistant,
       :google_write_conflict_protection,
       parse_bool.(System.get_env("GOOGLE_WRITE_CONFLICT_PROTECTION"))

config :assistant,
       :google_write_lease_enforcement,
       parse_bool.(System.get_env("GOOGLE_WRITE_LEASE_ENFORCEMENT"))

config :assistant,
       :google_write_audit_history,
       parse_bool.(System.get_env("GOOGLE_WRITE_AUDIT_HISTORY"))

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

# Slack
if signing_secret = System.get_env("SLACK_SIGNING_SECRET") do
  config :assistant, :slack_signing_secret, signing_secret
end

if client_id = System.get_env("SLACK_CLIENT_ID") do
  config :assistant, :slack_client_id, client_id
end

if client_secret = System.get_env("SLACK_CLIENT_SECRET") do
  config :assistant, :slack_client_secret, client_secret
end

if bot_token = System.get_env("SLACK_BOT_TOKEN") do
  config :assistant, :slack_bot_token, bot_token
end

# Discord Bot
if token = System.get_env("DISCORD_BOT_TOKEN") do
  config :assistant, :discord_bot_token, token
end

if public_key = System.get_env("DISCORD_PUBLIC_KEY") do
  config :assistant, :discord_public_key, public_key
end

if app_id = System.get_env("DISCORD_APPLICATION_ID") do
  config :assistant, :discord_application_id, app_id
end

# HubSpot
if api_key = System.get_env("HUBSPOT_API_KEY") do
  config :assistant, :hubspot_api_key, api_key
end

# Stripe billing
if secret_key = System.get_env("STRIPE_SECRET_KEY") do
  config :assistant, :stripe_secret_key, secret_key
end

if webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET") do
  config :assistant, :stripe_webhook_secret, webhook_secret
end

if price_id = System.get_env("STRIPE_PRO_PRICE_ID") do
  config :assistant, :stripe_pro_price_id, price_id
end

if meter_event_name = System.get_env("STRIPE_STORAGE_METER_EVENT_NAME") do
  config :assistant, :stripe_storage_meter_event_name, meter_event_name
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
