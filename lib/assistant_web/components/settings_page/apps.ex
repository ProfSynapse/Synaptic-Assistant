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

  import AssistantWeb.Components.DriveSettings, only: [drive_settings: 1]
  import AssistantWeb.Components.SyncTargetBrowser, only: [sync_target_browser: 1]

  def apps_section(assigns) do
    is_admin =
      case assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    connection_status = assigns[:connection_status] || %{}
    connector_states = assigns[:connector_states] || %{}
    workspace_enabled_groups = assigns[:workspace_enabled_groups] || %{}

    assigns =
      assigns
      |> assign(:is_admin, is_admin)
      |> assign(:connection_status, connection_status)
      |> assign(:connector_states, connector_states)
      |> assign(:workspace_enabled_groups, workspace_enabled_groups)

    ~H"""
    <section class="sa-card">
      <h2>Connected Apps</h2>
      <p>Manage your integrations and connected services.</p>

      <div class="sa-card-grid" style="margin-top: 1rem;">
        <.app_card
          :for={app <- @app_catalog}
          app={app}
          connection_status={@connection_status}
          connector_states={@connector_states}
          workspace_enabled_groups={@workspace_enabled_groups}
          is_admin={@is_admin}
        />
      </div>

      <.drive_settings
        :if={@google_connected}
        connected_drives={@connected_drives}
        available_drives={@available_drives}
        drives_loading={@drives_loading}
        has_google_token={GoogleAuth.configured?()}
        sync_scopes={@sync_scopes}
      />

      <.sync_target_browser
        open={@sync_target_browser_open}
        drives={@sync_target_drives}
        selected_drive={@sync_target_selected_drive}
        folders={@sync_target_folders}
        loading={@sync_target_loading}
        error={@sync_target_error}
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
  attr :connector_states, :map, required: true
  attr :workspace_enabled_groups, :map, required: true
  attr :is_admin, :boolean, required: true

  defp app_card(assigns) do
    app = assigns.app
    group = app.integration_group
    connection_status = Map.get(assigns.connection_status, group, :not_configured)
    workspace_enabled = Map.get(assigns.workspace_enabled_groups, group, true)
    user_enabled = Map.get(assigns.connector_states, group, false)
    inline_toggle = app.connect_type != :oauth
    setup_required = app.id == "telegram"

    toggle_enabled =
      inline_toggle and workspace_enabled and connection_status in [:connected, :not_connected]

    status =
      cond do
        not workspace_enabled ->
          :workspace_disabled

        connection_status == :not_configured ->
          :not_configured

        inline_toggle and not user_enabled ->
          :disabled

        connection_status == :connected ->
          :connected

        true ->
          :not_connected
      end

    assigns =
      assigns
      |> assign(:workspace_enabled, workspace_enabled)
      |> assign(:user_enabled, user_enabled)
      |> assign(:inline_toggle, inline_toggle)
      |> assign(:setup_required, setup_required)
      |> assign(:toggle_enabled, toggle_enabled)
      |> assign(:status, status)

    ~H"""
    <article class="sa-card">
      <div class="sa-row">
        <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
          <img src={@app.icon_path} alt={@app.name} class="sa-app-icon" />
          <h3>{@app.name}</h3>
        </div>

        <div style="display: flex; align-items: center; gap: 0.75rem;">
          <label :if={@inline_toggle} class={["sa-switch", !@toggle_enabled && "opacity-50"]}>
            <input
              type="checkbox"
              checked={@user_enabled}
              class="sa-switch-input"
              role="switch"
              aria-checked={to_string(@user_enabled)}
              aria-label={"Toggle #{@app.name}"}
              disabled={!@toggle_enabled}
              phx-click="toggle_connector"
              phx-value-app_id={@app.id}
              phx-value-group={@app.integration_group}
              phx-value-enabled={to_string(!@user_enabled)}
            />
            <span class="sa-switch-slider"></span>
          </label>
          <.link
            navigate={~p"/settings/apps/#{@app.id}"}
            class="sa-icon-btn"
            title={"Open #{@app.name} settings"}
          >
            <.icon name="hero-cog-6-tooth" class="h-4 w-4" />
          </.link>
          <.status_icon status={@status} />
        </div>
      </div>

      <p style="margin: 0.5rem 0 1rem; font-size: 0.875rem; color: var(--sa-text-secondary);">
        {@app.summary}
      </p>

      <.card_status_copy
        status={@status}
        is_admin={@is_admin}
        inline_toggle={@inline_toggle}
        setup_required={@setup_required}
      />
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

  defp status_icon(%{status: :workspace_disabled} = assigns) do
    ~H"""
    <span aria-label="Disabled by admin"><.icon name="hero-no-symbol" class="h-5 w-5 text-amber-500" /></span>
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

  defp card_status_copy(%{status: :connected, inline_toggle: true} = assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Enabled for your account.
    </p>
    """
  end

  defp card_status_copy(%{status: :disabled, inline_toggle: true} = assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Disabled for your account.
    </p>
    """
  end

  defp card_status_copy(%{status: :workspace_disabled} = assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Disabled by workspace admin.
    </p>
    """
  end

  defp card_status_copy(%{status: :not_configured, is_admin: true} = assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Configure this integration in Admin settings.
    </p>
    """
  end

  defp card_status_copy(%{status: :not_configured, setup_required: true} = assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Requires workspace setup plus personal account link.
    </p>
    """
  end

  defp card_status_copy(assigns) do
    ~H"""
    <p style="font-size: 0.8125rem; color: var(--sa-text-secondary); text-align: center;">
      Use settings to complete connection details.
    </p>
    """
  end
end
