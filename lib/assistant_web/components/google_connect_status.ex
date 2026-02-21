defmodule AssistantWeb.Components.GoogleConnectStatus do
  @moduledoc false

  use Phoenix.Component

  import AssistantWeb.CoreComponents, only: [icon: 1]

  attr :connected, :boolean, required: true
  attr :email, :string, default: nil

  def google_connect_status(assigns) do
    ~H"""
    <div class="sa-connect-status">
      <div :if={@connected} class="sa-connect-status-connected">
        <div class="sa-connect-status-info">
          <span class="sa-connect-status-badge sa-connect-status-badge--connected">
            <.icon name="hero-check-circle" class="h-4 w-4" />
            Connected
          </span>
          <span :if={@email} class="sa-connect-status-email">{@email}</span>
        </div>
        <button
          type="button"
          class="sa-btn secondary sa-btn--danger-text"
          phx-click="disconnect_google"
          data-confirm="Disconnect Google Workspace? The assistant will lose access to Gmail, Calendar, and Drive for this account."
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
        <button
          type="button"
          class="sa-btn"
          phx-click="connect_google"
        >
          <.icon name="hero-link" class="h-4 w-4" />
          Connect Google Workspace
        </button>
      </div>
    </div>
    """
  end
end
