# lib/assistant_web/components/settings_page/apps.ex
#
# Apps & Connections section component for the settings page. Renders a grid of
# integration cards with four status states derived from ConnectionValidator:
# :connected (API responded + enabled), :disabled (API responded but toggled off),
# :not_connected (keys exist but API handshake failed), :not_configured (no keys).
# All detail actions live on /settings/apps/:app_id. Used by settings_page.ex.

defmodule AssistantWeb.Components.SettingsPage.Apps do
  @moduledoc false

  use AssistantWeb, :html

  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.IntegrationSettings.Registry

  import AssistantWeb.Components.DriveSettings, only: [drive_settings: 1]

  def apps_section(assigns) do
    is_admin =
      case assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    all_settings = assigns[:integration_settings] || []
    connection_status = assigns[:connection_status] || %{}

    # Groups where the _enabled key has been explicitly set to "false".
    # When no _enabled key exists in DB (source :none), the group defaults to enabled.
    disabled_groups =
      all_settings
      |> Enum.filter(fn s ->
        Registry.enabled_key?(s.key) and s.source != :none and s.masked_value == "false"
      end)
      |> Enum.map(& &1.group)
      |> MapSet.new()

    assigns =
      assigns
      |> assign(:is_admin, is_admin)
      |> assign(:connection_status, connection_status)
      |> assign(:disabled_groups, disabled_groups)

    ~H"""
    <section class="sa-card">
      <h2>Connected Apps</h2>
      <p>Manage your integrations and connected services.</p>

      <div class="sa-card-grid" style="margin-top: 1rem;">
        <.app_card
          :for={app <- @app_catalog}
          app={app}
          connection_status={@connection_status}
          disabled_groups={@disabled_groups}
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
  attr :connection_status, :map, required: true
  attr :disabled_groups, :any, required: true
  attr :is_admin, :boolean, required: true

  defp app_card(assigns) do
    app = assigns.app
    group = app.integration_group
    conn_status = Map.get(assigns.connection_status, group, :not_configured)
    explicitly_disabled = MapSet.member?(assigns.disabled_groups, group)

    # Four-state status derived from ConnectionValidator + toggle state:
    # :connected — API handshake succeeded and integration enabled
    # :disabled — API handshake succeeded but explicitly toggled off
    # :not_connected — keys exist but API handshake failed
    # :not_configured — no keys configured at all
    status =
      cond do
        conn_status == :connected and not explicitly_disabled -> :connected
        conn_status == :connected and explicitly_disabled -> :disabled
        conn_status == :not_connected -> :not_connected
        true -> :not_configured
      end

    # Show toggle when keys exist (connected or not_connected) regardless of handshake result
    has_keys = conn_status in [:connected, :not_connected]
    enabled = status == :connected

    assigns =
      assigns
      |> assign(:has_keys, has_keys)
      |> assign(:enabled, enabled)
      |> assign(:status, status)

    ~H"""
    <article class="sa-card">
      <div class="sa-row">
        <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
          <img src={@app.icon_path} alt={@app.name} class="sa-app-icon" />
          <h3>{@app.name}</h3>
        </div>

        <div style="display: flex; align-items: center; gap: 0.75rem;">
          <label :if={@is_admin and @has_keys and @app.connect_type != :oauth} class="sa-switch">
            <input
              type="checkbox"
              checked={@enabled}
              class="sa-switch-input"
              role="switch"
              aria-checked={to_string(@enabled)}
              aria-label={"Toggle #{@app.name}"}
              phx-click="toggle_integration"
              phx-value-group={@app.integration_group}
              phx-value-enabled={to_string(!@enabled)}
            />
            <span class="sa-switch-slider"></span>
          </label>
          <.status_icon status={@status} />
        </div>
      </div>

      <p style="margin: 0.5rem 0 1rem; font-size: 0.875rem; color: var(--sa-text-secondary);">
        {@app.summary}
      </p>

      <.card_actions app={@app} status={@status} is_admin={@is_admin} />
    </article>
    """
  end

  defp status_icon(%{status: :connected} = assigns) do
    ~H"""
    <span aria-label="Connected"><.icon name="hero-check-circle" class="h-5 w-5 text-green-500" /></span>
    """
  end

  defp status_icon(%{status: :disabled} = assigns) do
    ~H"""
    <span aria-label="Disabled"><.icon name="hero-x-circle" class="h-5 w-5 text-zinc-400" /></span>
    """
  end

  defp status_icon(%{status: :not_connected} = assigns) do
    ~H"""
    <span aria-label="Connection failed"><.icon name="hero-x-circle" class="h-5 w-5 text-red-400" /></span>
    """
  end

  defp status_icon(assigns) do
    ~H"""
    <span aria-label="Not configured"><.icon name="hero-x-circle" class="h-5 w-5 text-zinc-400" /></span>
    """
  end

  # --- Card action buttons ---

  # Connected, disabled, or not_connected — full-width "Settings" button
  defp card_actions(%{status: status} = assigns)
       when status in [:connected, :disabled, :not_connected] do
    ~H"""
    <.link
      navigate={~p"/settings/apps/#{@app.id}"}
      class="sa-btn secondary"
      style="width: 100%; justify-content: center; display: inline-flex; text-decoration: none; box-sizing: border-box;"
    >
      <.icon name="hero-cog-6-tooth" class="h-4 w-4" /> Settings
    </.link>
    """
  end

  # Not configured — admin gets "Set Up" button
  defp card_actions(%{status: :not_configured, is_admin: true} = assigns) do
    ~H"""
    <.link
      navigate={~p"/settings/apps/#{@app.id}"}
      class="sa-btn"
      style="width: 100%; justify-content: center; display: inline-flex; text-decoration: none; box-sizing: border-box;"
    >
      <.icon name="hero-cog-6-tooth" class="h-4 w-4" /> Set Up
    </.link>
    """
  end

  # Not configured — non-admin gets informational text
  defp card_actions(assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Contact your admin to configure this integration.
    </p>
    """
  end
end
