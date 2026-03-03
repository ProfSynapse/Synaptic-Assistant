# lib/assistant_web/components/settings_page/app_detail.ex
#
# Per-app setup page component. Renders a dedicated detail view for a single
# integration including setup instructions and admin-only API key configuration.
# Accessed via /settings/apps/:app_id. Used by settings_page.ex when current_app
# is set.

defmodule AssistantWeb.Components.SettingsPage.AppDetail do
  @moduledoc false

  use AssistantWeb, :html

  import AssistantWeb.Components.AdminIntegrations, only: [admin_integrations: 1]

  def app_detail_section(assigns) do
    is_admin =
      case assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    assigns = assign(assigns, :is_admin, is_admin)

    ~H"""
    <div>
      <header class="sa-page-header">
        <div style="display: flex; align-items: center; gap: 1rem;">
          <.link navigate={~p"/settings/apps"} class="sa-icon-btn" title="Back to Apps">
            <.icon name="hero-arrow-left" class="h-5 w-5" />
          </.link>
          <img src={@current_app.icon_path} alt={@current_app.name} class="sa-app-icon" style="width: 2rem; height: 2rem;" />
          <div>
            <h1 style="margin: 0;">{@current_app.name}</h1>
            <p class="sa-page-subtitle" style="margin: 0;">{@current_app.summary}</p>
          </div>
        </div>
      </header>

      <section class="sa-card" style="margin-top: 1.5rem;">
        <h2>Setup Instructions</h2>
        <ol style="padding-left: 1.5rem; margin-top: 0.75rem;" class="sa-setup-steps">
          <li :for={{step, _idx} <- Enum.with_index(@current_app.setup_instructions)} style="margin-bottom: 0.5rem; line-height: 1.6;">
            {step}
          </li>
        </ol>
      </section>

      <section :if={@current_app.connect_type == :oauth} class="sa-card" style="margin-top: 1.5rem;">
        <h2>Connection</h2>
        <div style="margin-top: 0.75rem;">
          <div :if={@google_connected} style="display: flex; align-items: center; gap: 0.75rem;">
            <.icon name="hero-check-circle" class="h-6 w-6 text-green-500" />
            <span>Connected{if @google_email, do: " as #{@google_email}", else: ""}</span>
            <button
              type="button"
              class="sa-btn secondary"
              style="margin-left: auto;"
              phx-click="disconnect_google"
              data-confirm="Disconnect Google Workspace?"
            >
              Disconnect
            </button>
          </div>
          <div :if={!@google_connected}>
            <button type="button" class="sa-btn" phx-click="connect_google">
              <.icon name="hero-link" class="h-4 w-4" /> Connect Google Account
            </button>
          </div>
        </div>
      </section>

      <section :if={@is_admin and @app_integration_settings != []} class="sa-card" style="margin-top: 1.5rem;">
        <h2>Configuration</h2>
        <p style="margin-top: 0.25rem; margin-bottom: 1rem;" class="sa-page-subtitle">
          API keys and tokens for this integration. Values saved here override environment variables.
        </p>
        <.admin_integrations settings={@app_integration_settings} />
      </section>

      <div :if={!@is_admin and @current_app.connect_type == :api_key} class="sa-card" style="margin-top: 1.5rem;">
        <div style="display: flex; align-items: center; gap: 0.75rem;">
          <.icon name="hero-information-circle" class="h-5 w-5 text-zinc-400" />
          <span>Contact your workspace admin to configure this integration.</span>
        </div>
      </div>
    </div>
    """
  end
end
