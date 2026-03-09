# lib/assistant_web/components/settings_page/app_detail.ex
#
# Per-app setup page component. Renders a dedicated detail view for a single
# integration including setup instructions and admin-only API key configuration.
# Accessed via /settings/apps/:app_id. Used by settings_page.ex when current_app
# is set.

defmodule AssistantWeb.Components.SettingsPage.AppDetail do
  @moduledoc false

  use AssistantWeb, :html

  import AssistantWeb.Components.GoogleWorkspaceDriveAccess,
    only: [google_workspace_drive_access: 1]

  def app_detail_section(assigns) do
    is_admin =
      case assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    assigns = assign(assigns, :is_admin, is_admin)

    ~H"""
    <div class="sa-app-detail">
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

      <details class="sa-accordion" style="margin-top: 1.5rem;">
        <summary>Setup Instructions</summary>
        <div class="sa-accordion-body">
          <ol class="sa-setup-steps">
            <li :for={{step, idx} <- Enum.with_index(@current_app.setup_instructions, 1)}>
              <span class="sa-step-number">{idx}</span>
              <span>{step}</span>
            </li>
          </ol>
          <div :if={@current_app[:portal_url] || @current_app[:docs_url]} class="sa-docs-links">
            <a
              :if={@current_app[:portal_url]}
              href={@current_app.portal_url}
              target="_blank"
              rel="noopener"
              class="sa-docs-link"
            >
              <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
              Open developer console
            </a>
            <a
              :if={@current_app[:docs_url]}
              href={@current_app.docs_url}
              target="_blank"
              rel="noopener"
              class="sa-docs-link"
            >
              <.icon name="hero-book-open" class="h-4 w-4" />
              View setup guide
            </a>
          </div>
        </div>
      </details>

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

      <section
        :if={@current_app.id == "google_workspace"}
        class="sa-card sa-app-panel sa-app-panel--drive"
        style="margin-top: 1.5rem;"
      >
        <.google_workspace_drive_access
          connected_sources={@connected_storage_sources}
          available_sources={@available_storage_sources}
          sources_loading={@storage_sources_loading}
          provider_connected={@google_connected}
          storage_scopes={@storage_scopes}
          selected_source={@file_picker_selected_source}
          draft_scopes={Map.values(@file_picker_selection_draft || %{})}
          nodes={@file_picker_nodes}
          root_keys={@file_picker_root_keys}
          expanded={@file_picker_expanded}
          loading={@file_picker_loading}
          loading_nodes={@file_picker_loading_nodes}
          error={@file_picker_error}
          dirty={@file_picker_dirty}
        />
      </section>

      <section :if={@current_app.id == "telegram"} class="sa-card" style="margin-top: 1.5rem;">
        <h2>Telegram Account</h2>
        <p style="margin-top: 0.25rem; margin-bottom: 1rem;" class="sa-page-subtitle">
          Link your own Telegram account with a one-time deep link. Only linked Telegram accounts can chat with this bot.
        </p>

        <div :if={!@telegram_bot_configured} class="sa-drive-notice sa-drive-notice--info">
          <.icon name="hero-information-circle" class="h-5 w-5" />
          <span :if={@is_admin}>
            Configure Telegram credentials in Admin, then generate a connect link here.
          </span>
          <span :if={!@is_admin}>
            Your workspace admin must configure the Telegram bot before you can link your account.
          </span>
        </div>

        <div
          :if={@telegram_bot_configured and !@telegram_enabled}
          class="sa-drive-notice sa-drive-notice--warning"
        >
          <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
          <span :if={@is_admin}>
            Telegram is currently disabled. Re-enable it from the Apps list to receive messages.
          </span>
          <span :if={!@is_admin}>
            Telegram is currently disabled by your workspace admin.
          </span>
        </div>

        <div
          :if={@telegram_bot_configured and @telegram_enabled and @telegram_identity}
          style="display: flex; flex-direction: column; gap: 0.75rem;"
        >
          <div style="display: flex; align-items: center; gap: 0.75rem;">
            <.icon name="hero-check-circle" class="h-6 w-6 text-green-500" />
            <div>
              <p style="margin: 0; font-weight: 600;">
                Connected as {telegram_identity_label(@telegram_identity)}
              </p>
              <p class="sa-page-subtitle" style="margin: 0;">
                Telegram ID {@telegram_identity.external_id}
              </p>
            </div>
          </div>

          <div style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
            <button type="button" class="sa-btn secondary" phx-click="refresh_telegram_link_status">
              <.icon name="hero-arrow-path" class="h-4 w-4" /> Refresh Status
            </button>
            <button
              type="button"
              class="sa-btn secondary"
              phx-click="disconnect_telegram"
              data-confirm="Disconnect your linked Telegram account?"
            >
              Disconnect Telegram
            </button>
          </div>
        </div>

        <div
          :if={@telegram_bot_configured and @telegram_enabled and is_nil(@telegram_identity)}
          style="display: flex; flex-direction: column; gap: 0.75rem;"
        >
          <p style="margin: 0;">
            Generate a one-time link, open it in Telegram, and Telegram will attach your account to this workspace user.
          </p>

          <div style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
            <button type="button" class="sa-btn" phx-click="generate_telegram_connect_link">
              <.icon name="hero-link" class="h-4 w-4" /> Generate Connect Link
            </button>
            <button
              :if={@telegram_connect_url}
              type="button"
              class="sa-btn secondary"
              phx-click="refresh_telegram_link_status"
            >
              <.icon name="hero-arrow-path" class="h-4 w-4" /> Refresh Status
            </button>
          </div>

          <div :if={@telegram_connect_url} class="rounded-lg border border-zinc-200 bg-zinc-50 p-4">
            <p style="margin: 0 0 0.5rem; font-weight: 600;">Link Ready</p>
            <p class="sa-page-subtitle" style="margin: 0 0 0.75rem;">
              Open this link in Telegram{if(@telegram_bot_username, do: " for @" <> @telegram_bot_username, else: "")}. It expires {telegram_expiry_text(@telegram_connect_expires_at)} and only works once.
            </p>
            <a
              href={@telegram_connect_url}
              target="_blank"
              rel="noopener"
              class="sa-btn"
              style="display: inline-flex; text-decoration: none;"
            >
              <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" /> Open Telegram Link
            </a>
            <p class="sa-page-subtitle" style="margin: 0.75rem 0 0; word-break: break-all;">
              {@telegram_connect_url}
            </p>
          </div>
        </div>
      </section>

      <section
        :if={@current_app.connect_type == :api_key and @current_app.id != "telegram"}
        class="sa-card"
        style="margin-top: 1.5rem;"
      >
        <h2>Workspace Configuration</h2>
        <p style="margin-top: 0.25rem; margin-bottom: 1rem;" class="sa-page-subtitle">
          API keys and secrets are managed in Admin and applied workspace-wide.
        </p>
        <.link
          :if={@is_admin}
          navigate={~p"/settings/admin/integrations/#{@current_app.integration_group}"}
          class="sa-btn secondary"
          style="display: inline-flex; text-decoration: none;"
        >
          <.icon name="hero-cog-6-tooth" class="h-4 w-4" /> Manage in Admin
        </.link>
        <p :if={!@is_admin} style="margin: 0;">
          Contact your workspace admin to update credentials.
        </p>
      </section>

      <section class="sa-card sa-app-panel" style="margin-top: 1.5rem;">
        <div class="sa-app-panel-header">
          <div>
            <h2>Personal Tool Access</h2>
            <p style="margin-top: 0.25rem;" class="sa-page-subtitle">
              Control which {@current_app.name} tools the model can use for your account.
            </p>
          </div>
        </div>

        <div :if={@personal_skill_permissions == []} class="sa-empty">
          No {@current_app.name} tools are available for personal control.
        </div>

        <div :if={@personal_skill_permissions != []} class="sa-personal-tools-table-shell">
          <table class="sa-table sa-personal-tools-table">
            <thead>
              <tr>
                <th>Domain</th>
                <th>Skill</th>
                <th>Enabled</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={perm <- @personal_skill_permissions}>
                <td>
                  <span class="sa-personal-tools-domain-pill">{perm.domain_label}</span>
                </td>
                <td>
                  <div class="sa-personal-tools-skill">
                    <span class="sa-personal-tools-skill-label">{perm.skill_label}</span>
                    <span class="sa-personal-tools-skill-meta">
                      {perm.domain_label} personal tool access
                    </span>
                  </div>
                </td>
                <td>
                  <label class="sa-switch sa-personal-tools-switch">
                    <input
                      type="checkbox"
                      checked={perm.enabled}
                      class="sa-switch-input"
                      role="switch"
                      aria-checked={to_string(perm.enabled)}
                      aria-label={"Toggle #{perm.skill_label}"}
                      phx-click="toggle_personal_skill"
                      phx-value-skill={perm.id}
                      phx-value-enabled={to_string(!perm.enabled)}
                    />
                    <span class="sa-switch-slider"></span>
                  </label>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  defp telegram_identity_label(%{display_name: display_name, external_id: external_id}) do
    case display_name do
      name when is_binary(name) and name != "" -> name
      _ -> "Telegram user #{external_id}"
    end
  end

  defp telegram_expiry_text(%DateTime{} = expires_at) do
    Calendar.strftime(expires_at, "%b %d at %I:%M %p UTC")
  end

  defp telegram_expiry_text(_expires_at), do: "soon"
end
