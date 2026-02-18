# lib/assistant/scheduler.ex — Quantum cron scheduler.
#
# Manages scheduled jobs (cron-based). Job definitions are configured
# in config/config.exs under `config :assistant, Assistant.Scheduler`.
# Workflow schedules will be added dynamically as workflows are created.

defmodule Assistant.Scheduler do
  use Quantum, otp_app: :assistant
end
