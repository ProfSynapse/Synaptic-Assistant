# config/prod.exs — Production environment configuration.
#
# Minimal compile-time config. All secrets and host-specific values
# are in runtime.exs (loaded at boot, not compile time).

import Config

# Force SSL in production with HSTS header.
# Health check endpoint is excluded so Railway probes work over HTTP.
config :assistant, AssistantWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto]],
  exclude: [
    hosts: ["localhost", "127.0.0.1"]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration is done in config/runtime.exs.
