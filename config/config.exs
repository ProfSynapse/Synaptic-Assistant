# config/config.exs — Base configuration shared across all environments.
#
# Loaded before any dependency and restricted to this project.
# Runtime secrets belong in runtime.exs, not here.

import Config

config :assistant, :scopes,
  settings_user: [
    default: true,
    module: Assistant.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:settings_user, :id],
    schema_key: :settings_user_id,
    schema_type: :binary_id,
    schema_table: :settings_users,
    test_data_fixture: Assistant.AccountsFixtures,
    test_setup_helper: :register_and_log_in_settings_user
  ]

# General application configuration
config :assistant,
  ecto_repos: [Assistant.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Phoenix endpoint configuration
config :assistant, AssistantWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AssistantWeb.ErrorHTML, json: AssistantWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Assistant.PubSub,
  live_view: [signing_salt: "MN4yWf8K"]

# JSON library for Phoenix
config :phoenix, :json_library, Jason

# Mailer
config :assistant, Assistant.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

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

# Tailwind CSS (standalone CLI, no Node.js required)
config :tailwind,
  version: "4.0.9",
  default: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
