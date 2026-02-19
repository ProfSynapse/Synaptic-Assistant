# lib/assistant/application.ex — OTP Application entry point.
#
# Defines the supervision tree for the Skills-First AI Assistant.
# Children start in order: infrastructure first, then skill system, then
# orchestrator infrastructure, then web endpoint.

defmodule Assistant.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Google OAuth2 (conditional — only when credentials are configured)
    children =
      [
        # Config loader (must be first — other children depend on ETS config)
        Assistant.Config.Loader,

        # Prompt template loader (after Config.Loader — reads config/prompts/*.yaml)
        Assistant.Config.PromptLoader,

        # Encryption vault (must start before Repo consumers that use Cloak types)
        Assistant.Vault,

        # Infrastructure
        Assistant.Repo,
        {DNSCluster, query: Application.get_env(:assistant, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Assistant.PubSub}
      ] ++
        # Google Chat bot service account (conditional — only when credentials are configured).
        # Used ONLY for chat.bot scope. Per-user OAuth2 is stateless (no supervised process).
        maybe_goth() ++
        [
          # Cron scheduler (before Oban — scheduled jobs may enqueue Oban work)
          Assistant.Scheduler,

          # Job processing
          {Oban, Application.fetch_env!(:assistant, Oban)},

          # Workflow cron loader (after Scheduler + Oban — registers cron jobs for workflows)
          Assistant.Scheduler.QuantumLoader,

          # Skill system (Task.Supervisor must start before Registry and Executor)
          {Task.Supervisor, name: Assistant.Skills.TaskSupervisor},
          Assistant.Skills.Registry,
          Assistant.Skills.Watcher,

          # Orchestrator (process registries + DynamicSupervisor for per-conversation engines)
          {Registry, keys: :unique, name: Assistant.Orchestrator.EngineRegistry},
          {Registry, keys: :unique, name: Assistant.SubAgent.Registry},
          {DynamicSupervisor,
           name: Assistant.Orchestrator.ConversationSupervisor, strategy: :one_for_one},

          # Memory agent (must start before monitors that dispatch to it)
          {Assistant.Memory.Agent, user_id: "dev-user"},

          # Memory background triggers (subscribe to PubSub events from Engine)
          Assistant.Memory.ContextMonitor,
          Assistant.Memory.TurnClassifier,

          # Notification router (dedup + rule-based dispatch to channels)
          Assistant.Notifications.Router,

          # Web endpoint (last — depends on everything above)
          AssistantWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: Assistant.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AssistantWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Returns Goth child spec if Google service account credentials are configured.
  # Goth is now used ONLY for the Chat bot (chat.bot scope).
  # Per-user OAuth2 tokens are refreshed statelessly via Goth.Token.fetch/1
  # and do NOT require a supervised Goth process.
  defp maybe_goth do
    case Application.get_env(:assistant, :google_credentials) do
      nil ->
        []

      credentials when is_map(credentials) ->
        scopes = Assistant.Integrations.Google.Auth.scopes()

        [
          {Goth,
           name: Assistant.Goth,
           source: {:service_account, credentials, [scopes: scopes]}}
        ]
    end
  end
end
