# config/dev.exs — Development environment configuration.
#
# Settings for local development. Database, endpoint, and logging.

import Config

# Database configuration for development
config :assistant, Assistant.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "assistant_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Development endpoint — webhooks-only, no live reload of HTML
config :assistant, AssistantWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "cE7iGbkPg82Z/NQJ3+qLJxMV8U40x0ykw7fhsotbBZXbf6HdctY/V0FNHuVZ3pSa",
  watchers: []

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Disable Oban job processing in dev by default (enable as needed)
config :assistant, Oban, testing: :manual
