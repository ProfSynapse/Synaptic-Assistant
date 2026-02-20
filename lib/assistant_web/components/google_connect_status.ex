defmodule AssistantWeb.Components.GoogleConnectStatus do
  @moduledoc false

  use Phoenix.Component

  import AssistantWeb.CoreComponents, only: [icon: 1]

  attr :connected, :boolean, required: true
  attr :email, :string, default: nil

  def google_connect_status(assigns) do
    ~H"""
    <div class="sa-google-status">
      <div :if={@connected} class="sa-google-status-connected">
        <div class="sa-google-status-info">
          <span class="sa-google-status-badge sa-google-status-badge--connected">
            <.icon name="hero-check-circle" class="h-4 w-4" />
            Connected
          </span>
          <span :if={@email} class="sa-google-status-email">{@email}</span>
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

      <div :if={!@connected} class="sa-google-status-disconnected">
        <span class="sa-google-status-badge sa-google-status-badge--disconnected">
          <.icon name="hero-x-circle" class="h-4 w-4" />
          Not connected
        </span>
        <.link
          href="/auth/google/start?from=settings"
          class="sa-btn"
        >
          <.icon name="hero-link" class="h-4 w-4" />
          Connect Google Workspace
        </.link>
      </div>
    </div>
    """
  end
end
