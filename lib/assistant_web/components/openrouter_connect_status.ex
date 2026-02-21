defmodule AssistantWeb.Components.OpenRouterConnectStatus do
  @moduledoc false

  use Phoenix.Component

  import AssistantWeb.CoreComponents, only: [icon: 1]

  attr :connected, :boolean, required: true

  def openrouter_connect_status(assigns) do
    ~H"""
    <div class="sa-connect-status">
      <div :if={@connected} class="sa-connect-status-connected">
        <div class="sa-connect-status-info">
          <span class="sa-connect-status-badge sa-connect-status-badge--connected">
            <.icon name="hero-check-circle" class="h-4 w-4" />
            Connected
          </span>
        </div>
        <button
          type="button"
          class="sa-btn secondary sa-btn--danger-text"
          phx-click="disconnect_openrouter"
          data-confirm="Disconnect OpenRouter? The assistant will use the system-level API key instead."
        >
          <.icon name="hero-arrow-right-on-rectangle" class="h-4 w-4" />
          Disconnect
        </button>
      </div>

      <div :if={!@connected} class="sa-connect-status-disconnected">
        <span class="sa-connect-status-badge sa-connect-status-badge--disconnected">
          <.icon name="hero-x-circle" class="h-4 w-4" />
          Not connected
        </span>
        <.link
          href="/settings_users/auth/openrouter"
          class="sa-btn"
        >
          <.icon name="hero-link" class="h-4 w-4" />
          Connect OpenRouter
        </.link>
      </div>
    </div>
    """
  end
end
