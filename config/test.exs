# config/test.exs — Test environment configuration.
#
# Async-safe database (SQL sandbox), inline Oban, reduced logging.

import Config

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

# Oban: inline mode for deterministic test execution, no cron plugins
config :assistant, Oban, testing: :inline, plugins: false

# Cloak encryption key for tests (deterministic, NOT used in prod)
config :assistant, Assistant.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      # 32-byte test-only key
      key: Base.decode64!("dCtzMVByc1hTZ3RwNGNSRVlDemVxUCtiaGs2UGxGY1k=")
    }
  ]

# Reduce log noise in tests
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix, sort_verified_routes_query_params: true
