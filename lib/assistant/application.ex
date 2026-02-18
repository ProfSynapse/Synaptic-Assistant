# lib/assistant/application.ex — OTP Application entry point.
#
# Defines the supervision tree for the Skills-First AI Assistant.
# Children start in order: infrastructure first, then services, then web endpoint.

defmodule Assistant.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Infrastructure (start first)
      Assistant.Repo,
      {DNSCluster, query: Application.get_env(:assistant, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Assistant.PubSub},

      # Job processing
      {Oban, Application.fetch_env!(:assistant, Oban)},

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
end
