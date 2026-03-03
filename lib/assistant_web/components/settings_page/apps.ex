# lib/assistant_web/components/settings_page/apps.ex
#
# Apps & Connections section component for the settings page. Renders a grid of
# integration cards, each showing connection status. OAuth services (Google)
# show "Connected" when @google_connected is true. API-key services show
# "Configured" when at least one key is set. All detail actions live on
# /settings/apps/:app_id. Used by settings_page.ex.

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

    # Build a set of groups that have at least one configured API key
    # (excludes _enabled toggle keys — only counts real credentials)
    configured_groups =
      all_settings
      |> Enum.filter(fn s -> not Registry.enabled_key?(s.key) and s.source != :none end)
      |> Enum.map(& &1.group)
      |> MapSet.new()

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
      |> assign(:configured_groups, configured_groups)
      |> assign(:disabled_groups, disabled_groups)

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
  attr :google_connected, :boolean, required: true
  attr :configured_groups, :any, required: true
  attr :disabled_groups, :any, required: true
  attr :is_admin, :boolean, required: true

  defp app_card(assigns) do
    app = assigns.app
    group = app.integration_group
    configured = MapSet.member?(assigns.configured_groups, group)

    enabled =
      if app.connect_type == :oauth do
        assigns.google_connected
      else
        # Default to enabled when configured; only disabled if explicitly toggled off
        explicitly_disabled = MapSet.member?(assigns.disabled_groups, group)
        configured and not explicitly_disabled
      end

    # Three-state status:
    # :connected — keys configured AND integration is enabled
    # :configured — keys exist but integration has been explicitly disabled
    # :not_set — no keys configured at all
    status =
      cond do
        configured and enabled -> :connected
        configured -> :configured
        true -> :not_set
      end

    assigns =
      assigns
      |> assign(:configured, configured)
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
          <label :if={@is_admin and @configured and @app.connect_type != :oauth} class="sa-switch">
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
          <.status_badge status={@status} />
        </div>
      </div>

      <p style="margin: 0.5rem 0 1rem; font-size: 0.875rem; color: var(--sa-text-secondary);">
        {@app.summary}
      </p>

      <.card_actions app={@app} status={@status} is_admin={@is_admin} />
    </article>
    """
  end

  defp status_badge(%{status: :connected} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">
      Connected
    </span>
    """
  end

  defp status_badge(%{status: :configured} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700">
      Configured
    </span>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-500">
      Not Set
    </span>
    """
  end

  # --- Card action buttons ---

  # Configured or Connected — full-width "Settings" button
  defp card_actions(%{status: status} = assigns) when status in [:connected, :configured] do
    ~H"""
    <.link
      navigate={~p"/settings/apps/#{@app.id}"}
      class="sa-btn secondary"
      style="width: 100%; justify-content: center; display: inline-flex; text-decoration: none;"
    >
      <.icon name="hero-cog-6-tooth" class="h-4 w-4" /> Settings
    </.link>
    """
  end

  # Not configured — admin gets "Set Up" button
  defp card_actions(%{status: :not_set, is_admin: true} = assigns) do
    ~H"""
    <.link
      navigate={~p"/settings/apps/#{@app.id}"}
      class="sa-btn"
      style="width: 100%; justify-content: center; display: inline-flex; text-decoration: none;"
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
