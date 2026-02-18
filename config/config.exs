# config/config.exs — Base configuration shared across all environments.
#
# Loaded before any dependency and restricted to this project.
# Runtime secrets belong in runtime.exs, not here.

import Config

# General application configuration
config :assistant,
  ecto_repos: [Assistant.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Phoenix endpoint configuration (webhooks-only, no HTML)
config :assistant, AssistantWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: AssistantWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Assistant.PubSub

# JSON library for Phoenix
config :phoenix, :json_library, Jason

# Suppress Tesla deprecation warnings from Google API libraries
config :tesla, disable_deprecated_builder_warning: true

# Oban job processing (Postgres-backed)
config :assistant, Oban,
  repo: Assistant.Repo,
  queues: [
    default: 10,
    compaction: 5,
    memory: 5,
    notifications: 3,
    email: 5,
    calendar: 3,
    scheduled: 5
  ]

# Quantum cron scheduler
config :assistant, Assistant.Scheduler, jobs: []

# Logger configuration
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :conversation_id, :skill, :agent_id]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
