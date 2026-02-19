# config/test.exs — Test environment configuration.
#
# Async-safe database (SQL sandbox), inline Oban, reduced logging.

import Config

# Required for config/config.yaml interpolation when app boots in test.
System.put_env("ENV_VAR", "test")
System.put_env("ELEVENLABS_VOICE_ID", "test-voice-id")

# Test database — use SQL sandbox for async tests
config :assistant, Assistant.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "assistant_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Test endpoint — fixed port, no server
config :assistant, AssistantWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "27fsLlwxFAdrfzZvsTKefyNOFNT2ucWuIv/xYSS2myafQ6FEGytY1Gew0fD2BWU2",
  server: false

# Oban: inline mode for deterministic test execution
config :assistant, Oban, testing: :inline

# Avoid runtime crashes in tests that exercise OpenRouter paths without mocks.
config :assistant, :openrouter_api_key, "test-openrouter-key"

# Reduce log noise in tests
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix, sort_verified_routes_query_params: true
