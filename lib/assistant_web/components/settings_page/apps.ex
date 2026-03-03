# lib/assistant_web/components/settings_page/apps.ex
#
# Apps & Connections section component for the settings page. Renders a grid of
# integration cards, each showing connection status. OAuth services (Google) have
# inline connect/disconnect. API-key services link to a dedicated setup page at
# /settings/apps/:app_id. Used by settings_page.ex.

defmodule AssistantWeb.Components.SettingsPage.Apps do
  @moduledoc false

  use AssistantWeb, :html

  alias Assistant.Integrations.Google.Auth, as: GoogleAuth

  import AssistantWeb.Components.DriveSettings, only: [drive_settings: 1]

  def apps_section(assigns) do
    is_admin =
      case assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    # Build a set of groups that have at least one configured key
    configured_groups =
      (assigns[:integration_settings] || [])
      |> Enum.filter(fn s -> s.source != :none end)
      |> Enum.map(& &1.group)
      |> MapSet.new()

    assigns =
      assigns
      |> assign(:is_admin, is_admin)
      |> assign(:configured_groups, configured_groups)

    ~H"""
    <section class="sa-card">
      <h2>Connected Apps</h2>
      <p>Manage your integrations and connected services.</p>

      <div class="sa-card-grid" style="margin-top: 1rem;">
        <.app_card
          :for={app <- @app_catalog}
          app={app}
          google_connected={@google_connected}
          configured_groups={@configured_groups}
          is_admin={@is_admin}
        />
      </div>

      <.drive_settings
        :if={@google_connected}
        connected_drives={@connected_drives}
        available_drives={@available_drives}
        drives_loading={@drives_loading}
        has_google_token={GoogleAuth.configured?()}
      />
      <div :if={!@google_connected} class="sa-drive-settings">
        <h3>Google Drive Access</h3>
        <div class="sa-drive-notice sa-drive-notice--info">
          <.icon name="hero-information-circle" class="h-5 w-5" />
          <span>Connect your Google account above to manage Drive access.</span>
        </div>
      </div>
    </section>
    """
  end

  attr :app, :map, required: true
  attr :google_connected, :boolean, required: true
  attr :configured_groups, :any, required: true
  attr :is_admin, :boolean, required: true

  defp app_card(assigns) do
    app = assigns.app

    connected =
      if app.connect_type == :oauth do
        assigns.google_connected
      else
        MapSet.member?(assigns.configured_groups, app.integration_group)
      end

    assigns = assign(assigns, :connected, connected)

    ~H"""
    <article class="sa-card">
      <div class="sa-row">
        <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
          <img src={@app.icon_path} alt={@app.name} class="sa-app-icon" />
          <h3>{@app.name}</h3>
        </div>

        <div style="display: flex; align-items: center; gap: 0.75rem;">
          <span :if={@connected} class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">
            Connected
          </span>
          <span :if={!@connected} class="inline-flex items-center rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-500">
            Not Set
          </span>
        </div>
      </div>

      <p style="margin: 0.5rem 0 1rem; font-size: 0.875rem; color: var(--sa-text-secondary);">
        {@app.summary}
      </p>

      <%= if @app.connect_type == :oauth do %>
        <div :if={!@connected}>
          <button type="button" class="sa-btn" style="width: 100%; justify-content: center;" phx-click="connect_google">
            <.icon name="hero-link" class="h-4 w-4" /> Connect
          </button>
        </div>
        <div :if={@connected} style="display: flex; gap: 0.5rem;">
          <.link navigate={~p"/settings/apps/#{@app.id}"} class="sa-btn secondary" style="flex: 1; justify-content: center;">
            <.icon name="hero-cog-6-tooth" class="h-4 w-4" /> Settings
          </.link>
          <button type="button" class="sa-btn secondary" style="flex: 1; justify-content: center;" phx-click="disconnect_google" data-confirm="Disconnect Google Workspace?">
            Disconnect
          </button>
        </div>
      <% else %>
        <.link navigate={~p"/settings/apps/#{@app.id}"} class="sa-btn" style="width: 100%; justify-content: center; display: inline-flex; text-decoration: none;">
          <.icon :if={!@connected} name="hero-plus-circle" class="h-4 w-4" />
          <.icon :if={@connected} name="hero-cog-6-tooth" class="h-4 w-4" />
          {if @connected, do: "Settings", else: "Set Up"}
        </.link>
      <% end %>
    </article>
    """
  end
end
