defmodule AssistantWeb.Components.SettingsPage.Admin do
  # Settings page admin section component.
  # Renders the allow list management, user card grid, user detail view,
  # integration catalog, and admin-only model management (providers + role defaults).
  @moduledoc false

  use AssistantWeb, :html

  import AssistantWeb.Components.AdminIntegrations, only: [admin_integrations: 1]
  import AssistantWeb.Components.SettingsPage.Models, only: [models_section: 1]

  import AssistantWeb.Components.SettingsPage.UserDetail,
    only: [user_detail_section: 1, user_create_section: 1]

  import AssistantWeb.Components.SettingsPage.Policies, only: [policies_section: 1]

  @managed_integration_groups ~w(google_workspace telegram slack discord google_chat hubspot elevenlabs)

  def admin_section(assigns) do
    ~H"""
    <section
      :if={!@current_scope.settings_user.is_admin and @can_bootstrap_admin}
      id="admin-bootstrap"
      class="sa-card"
      style="border-color: var(--sa-warning-border, #fcd34d); background: var(--sa-warning-bg, #fffbeb);"
    >
      <div>
        <h2>Initial Admin Bootstrap</h2>
        <p>
          No admin accounts exist yet. Claim admin access for your account to become the first
          workspace admin and billing owner.
        </p>
      </div>
      <.button id="claim-admin-btn" phx-click="claim_bootstrap_admin">
        Claim Admin Access
      </.button>
    </section>

    <section :if={@current_scope.settings_user.is_admin} class="space-y-6">
      <nav class="sa-admin-tabs" role="tablist">
        <button
          :for={
            {tab_id, tab_label} <- [
              {"integrations", "Integrations"},
              {"models", "Models"},
              {"users", "Users"},
              {"policies", "Policies"}
            ]
          }
          type="button"
          role="tab"
          class={"sa-admin-tab #{if @admin_tab == tab_id, do: "active"}"}
          aria-selected={to_string(@admin_tab == tab_id)}
          phx-click="switch_admin_tab"
          phx-value-tab={tab_id}
        >
          {tab_label}
        </button>
      </nav>

      <div :if={@admin_tab == "integrations"} class="sa-card">
        <div>
          <h2>Integrations</h2>
          <p>
            Workspace credentials are managed per integration with dedicated setup guides.
          </p>
        </div>

        <div class="sa-card-grid" style="margin-top: 1rem;">
          <article
            :for={integration <- managed_integration_catalog(@admin_integration_catalog)}
            class="sa-card"
          >
            <div class="sa-row">
              <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
                <img src={integration.icon_path} alt={integration.name} class="sa-app-icon" />
                <h3>{integration.name}</h3>
              </div>

              <div style="display: flex; align-items: center; gap: 0.75rem;">
                <label class="sa-switch">
                  <input
                    type="checkbox"
                    checked={Map.get(@workspace_enabled_groups, integration.integration_group, true)}
                    class="sa-switch-input"
                    role="switch"
                    aria-checked={to_string(Map.get(@workspace_enabled_groups, integration.integration_group, true))}
                    aria-label={"Toggle #{integration.name} globally"}
                    phx-click="toggle_integration"
                    phx-value-group={integration.integration_group}
                    phx-value-enabled={to_string(!Map.get(@workspace_enabled_groups, integration.integration_group, true))}
                  />
                  <span class="sa-switch-slider"></span>
                </label>
                <.link
                  navigate={~p"/settings/admin/integrations/#{integration.integration_group}"}
                  class="sa-icon-btn"
                  title={"Open #{integration.name} settings"}
                >
                  <.icon name="hero-cog-6-tooth" class="h-4 w-4" />
                </.link>
              </div>
            </div>

            <p style="margin: 0.5rem 0 0; font-size: 0.875rem; color: var(--sa-text-secondary);">
              {integration.summary}
            </p>
          </article>
        </div>
      </div>

      <div :if={@admin_tab == "models"}>
        <div class="space-y-6">
          <.admin_model_providers {assigns} />
          <.admin_role_defaults {assigns} />
          <.models_section {assigns} />
        </div>
      </div>

      <div :if={@admin_tab == "policies"}>
        <.policies_section {assigns} />
      </div>

      <div :if={@admin_tab == "users"} class="space-y-6">
        <.user_detail_section
          :if={@current_admin_user}
          user={@current_admin_user}
          current_user_id={@current_scope.settings_user.id}
        />

        <.user_create_section
          :if={@creating_new_user && !@current_admin_user}
          allowlist_form={@allowlist_form}
          managed_scopes={@managed_scopes}
        />

        <div :if={!@current_admin_user && !@creating_new_user} class="sa-card">
          <div class="sa-row" style="margin-bottom: 1rem;">
            <h2>User Management</h2>
            <button type="button" class="sa-btn secondary" phx-click="start_add_user">
              <.icon name="hero-plus" class="h-4 w-4" /> Add User
            </button>
          </div>

          <p class="sa-muted" style="margin-bottom: 1rem;">
            Admins manage one shared workspace account here. New users you add join this same
            workspace and count toward the shared plan seats.
          </p>

          <div style="margin-bottom: 1rem; max-width: 20rem;">
            <form phx-change="search_admin_users" phx-submit="search_admin_users">
              <input
                type="text"
                name="query"
                value={@admin_user_search}
                placeholder="Search users by email or name..."
                phx-debounce="300"
                class="sa-search-input"
                autocomplete="off"
              />
            </form>
          </div>

          <div class="sa-model-table-shell">
            <table class="sa-table sa-table-zebra">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Name</th>
                  <th>Role</th>
                  <th>Status</th>
                  <th>Enabled</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_admin_users == []}>
                  <td colspan="6" style="text-align: center; color: var(--sa-text-secondary);">
                    No users found.
                  </td>
                </tr>
                <tr :for={user <- @filtered_admin_users} id={"user-row-#{user.id}"}>
                  <td>{user.email}</td>
                  <td>{user.display_name || "—"}</td>
                  <td>
                    <span :if={user.is_admin} class="sa-badge sa-badge-info">Admin</span>
                    <span :if={!user.is_admin}>User</span>
                  </td>
                  <td>
                    <div style="display: flex; flex-wrap: wrap; gap: 4px;">
                      <span :if={user.has_linked_user} class="sa-badge sa-badge-success">Linked</span>
                      <span :if={user.has_openrouter_key} class="sa-badge sa-badge-success">OR Key</span>
                      <span :if={user.has_openai_key} class="sa-badge sa-badge-success">OAI Key</span>
                    </div>
                  </td>
                  <td>
                    <label class={["sa-switch", is_self?(user, @current_scope.settings_user.id) && "sa-switch-disabled"]}>
                      <input
                        type="checkbox"
                        checked={!user.disabled_at}
                        class="sa-switch-input"
                        role="switch"
                        aria-checked={to_string(!user.disabled_at)}
                        aria-label={"Toggle #{user.email} enabled"}
                        phx-click="toggle_user_disabled"
                        phx-value-id={user.id}
                        disabled={is_self?(user, @current_scope.settings_user.id)}
                      />
                      <span class="sa-switch-slider"></span>
                    </label>
                  </td>
                  <td>
                    <div style="display: flex; gap: 0.25rem;">
                      <button
                        type="button"
                        class="sa-icon-btn"
                        title="Edit User"
                        phx-click="edit_admin_user"
                        phx-value-id={user.id}
                      >
                        <.icon name="hero-pencil-square" class="h-4 w-4" />
                      </button>
                      <button
                        type="button"
                        class={["sa-icon-btn danger", is_self?(user, @current_scope.settings_user.id) && "sa-icon-btn-disabled"]}
                        title="Delete User"
                        phx-click="delete_admin_user"
                        phx-value-id={user.id}
                        data-confirm="Are you sure you want to delete this user? This action cannot be undone."
                        disabled={is_self?(user, @current_scope.settings_user.id)}
                      >
                        <.icon name="hero-trash" class="h-4 w-4" />
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def admin_integration_detail_section(assigns) do
    ~H"""
    <div>
      <header class="sa-page-header">
        <div style="display: flex; align-items: center; gap: 1rem;">
          <.link navigate={~p"/settings/admin"} class="sa-icon-btn" title="Back to Admin">
            <.icon name="hero-arrow-left" class="h-5 w-5" />
          </.link>
          <img
            src={@current_admin_integration.icon_path}
            alt={@current_admin_integration.name}
            class="sa-app-icon"
            style="width: 2rem; height: 2rem;"
          />
          <div>
            <h1 style="margin: 0;">{@current_admin_integration.name} Integration</h1>
            <p class="sa-page-subtitle" style="margin: 0;">{@current_admin_integration.summary}</p>
          </div>
        </div>
      </header>

      <section class="sa-card" style="margin-top: 1.5rem;">
        <h2>Setup Instructions</h2>
        <div
          :if={@current_admin_integration.integration_group == "google_chat"}
          class="overflow-x-auto"
          style="margin-top: 0.75rem;"
        >
          <p class="sa-page-subtitle" style="margin: 0 0 0.5rem;">
            Recommended values for the Google Chat service account:
          </p>
          <table class="sa-table">
            <thead>
              <tr>
                <th>Field</th>
                <th>Value</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{field, value} <- google_chat_service_account_fields()}>
                <td>{field}</td>
                <td>{value}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <ol class="sa-setup-steps" style="margin-top: 0.75rem;">
          <li :for={{step, idx} <- Enum.with_index(@current_admin_integration.setup_instructions, 1)}>
            <span class="sa-step-number">{idx}</span>
            <span>{step}</span>
          </li>
        </ol>

        <div
          :if={@current_admin_integration[:portal_url] || @current_admin_integration[:docs_url]}
          class="sa-docs-links"
          style="margin-top: 1rem;"
        >
          <a
            :if={@current_admin_integration[:portal_url]}
            href={@current_admin_integration.portal_url}
            target="_blank"
            rel="noopener"
            class="sa-docs-link"
          >
            <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
            Open developer console
          </a>
          <a
            :if={@current_admin_integration[:docs_url]}
            href={@current_admin_integration.docs_url}
            target="_blank"
            rel="noopener"
            class="sa-docs-link"
          >
            <.icon name="hero-book-open" class="h-4 w-4" />
            View setup guide
          </a>
        </div>
      </section>

      <section class="sa-card" style="margin-top: 1.5rem;">
        <h2>Workspace Credentials</h2>
        <p style="margin-top: 0.25rem;" class="sa-page-subtitle">
          Saved values apply to all users in this workspace.
        </p>

        <div style="margin-top: 1rem;">
          <.admin_integrations
            settings={@integration_settings}
            group_filter={@current_admin_integration.integration_group}
          />
        </div>
      </section>
    </div>
    """
  end

  defp admin_model_providers(assigns) do
    ~H"""
    <div class="sa-card">
      <div class="sa-row" style="align-items: baseline;">
        <h2>Model Providers</h2>
      </div>
      <p class="sa-muted">
        Connect providers to make their models available for role defaults and active model selection.
      </p>
      <div class="sa-card-grid">
        <article class="sa-card">
          <div class="sa-row">
            <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
              <img src="/images/apps/openrouter.svg" alt="OpenRouter" class="sa-app-icon" />
              <h3>OpenRouter</h3>
            </div>
            <div class="sa-row" style="gap: 0.5rem;">
              <button
                type="button"
                class="sa-icon-btn"
                phx-click="toggle_openrouter_key_form"
                aria-label="Use OpenRouter API key"
                aria-expanded={to_string(@openrouter_key_form_open)}
                title="Use API key"
              >
                <.icon name="hero-key" class="h-4 w-4" />
              </button>
              <button
                :if={!@openrouter_connected}
                type="button"
                class="sa-btn"
                phx-click="connect_openrouter"
              >
                Connect
              </button>
              <button
                :if={@openrouter_connected}
                type="button"
                class="sa-btn secondary"
                phx-click="disconnect_openrouter"
                data-confirm="Disconnect OpenRouter? The assistant will use the system-level API key instead."
              >
                Disconnect
              </button>
            </div>
          </div>
          <p class="sa-muted" style="margin-top: 0.5rem;">
            Status:
            <span :if={@openrouter_connected}>Connected</span>
            <span :if={!@openrouter_connected}>Not connected</span>
          </p>
          <div :if={@openrouter_key_form_open} style="margin-top: 0.75rem;">
            <.form for={@openrouter_key_form} id="openrouter-key-form" phx-submit="save_openrouter_api_key">
              <.field
                type="password"
                field={@openrouter_key_form[:api_key]}
                label="OpenRouter API key"
                required
                no_margin
              />
              <button type="submit" class="sa-btn secondary">Validate & Connect</button>
            </.form>
          </div>
        </article>

        <article class="sa-card">
          <div class="sa-row">
            <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
              <img src="/images/apps/openai.svg" alt="OpenAI" class="sa-app-icon" />
              <h3>OpenAI</h3>
            </div>
            <div class="sa-row" style="gap: 0.5rem;">
              <button
                type="button"
                class="sa-icon-btn"
                phx-click="toggle_openai_key_form"
                aria-label="Use OpenAI API key"
                aria-expanded={to_string(@openai_key_form_open)}
                title="Use API key"
              >
                <.icon name="hero-key" class="h-4 w-4" />
              </button>
              <button :if={!@openai_connected} type="button" class="sa-btn" phx-click="connect_openai">
                Connect
              </button>
              <button
                :if={@openai_connected}
                type="button"
                class="sa-btn secondary"
                phx-click="disconnect_openai"
                data-confirm="Disconnect OpenAI?"
              >
                Disconnect
              </button>
            </div>
          </div>
          <p class="sa-muted" style="margin-top: 0.5rem;">
            Status:
            <span :if={@openai_connected}>Connected</span>
            <span :if={!@openai_connected}>Not connected</span>
          </p>
          <p class="sa-muted" style="margin-top: 0.25rem;">
            Connect starts ChatGPT OAuth (Codex-compatible). Use the key icon to manually add your OpenAI API key.
          </p>
          <div :if={@openai_key_form_open} style="margin-top: 0.75rem;">
            <.form for={@openai_key_form} id="openai-key-form" phx-submit="save_openai_api_key">
              <.field type="password" field={@openai_key_form[:api_key]} label="OpenAI API key" required no_margin />
              <button type="submit" class="sa-btn secondary">Validate & Connect</button>
            </.form>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp admin_role_defaults(assigns) do
    ~H"""
    <div class="sa-card">
      <h2>Role Defaults</h2>
      <p class="sa-muted">{@model_defaults_description}</p>

      <.form
        for={@model_defaults_form}
        id="model-defaults-form"
        phx-change="change_model_defaults"
        phx-submit="save_model_defaults"
        class="sa-model-defaults-form"
      >
        <div class="sa-model-defaults-grid">
          <div :for={role <- @model_default_roles} class="sa-model-default-row">
            <div class="sa-model-default-meta">
              <div class="sa-model-default-title">
                <span class="sa-model-default-role">{role.label}</span>
                <span class="sa-muted" style="font-size: 0.8rem;">
                  {model_default_source_label(@model_default_sources, @model_defaults_mode, role.key)}
                </span>
                <button
                  type="button"
                  class="sa-role-tooltip"
                  aria-label={"About #{role.label}"}
                  title={role.tooltip}
                >
                  <.icon name="hero-information-circle" class="h-4 w-4" />
                  <span class="sa-role-tooltip-bubble">{role.tooltip}</span>
                </button>
              </div>
            </div>
            <div class="sa-model-default-selects" style="display: flex; gap: 0.75rem; flex: 1; min-width: 0;">
              <div style="flex: 1; min-width: 0;">
                <.field
                  type="select"
                  name={"defaults[#{role.key}]"}
                  label={"Primary model for #{role.label}"}
                  label_class="sr-only"
                  no_margin={true}
                  options={@model_options}
                  selected={Map.get(@model_defaults, Atom.to_string(role.key))}
                  prompt="Primary"
                />
              </div>
              <div style="flex: 1; min-width: 0;">
                <.field
                  type="select"
                  name={"defaults[#{role.fallback_key}]"}
                  label={"Fallback model for #{role.label}"}
                  label_class="sr-only"
                  no_margin={true}
                  options={@model_options}
                  selected={Map.get(@model_defaults, Atom.to_string(role.fallback_key))}
                  prompt="Fallback"
                />
              </div>
            </div>
          </div>
        </div>
        <p class="sa-muted">{@model_defaults_notice}</p>
      </.form>
    </div>
    """
  end

  defp model_default_source_label(source_map, _mode, role_key) do
    case Map.get(source_map || %{}, Atom.to_string(role_key), :system) do
      :user -> "Admin override"
      :global -> "Admin default"
      :system -> "System fallback"
    end
  end

  defp is_self?(user, current_user_id), do: user.id == current_user_id

  defp managed_integration_catalog(catalog) when is_list(catalog) do
    Enum.filter(catalog, &(&1.integration_group in @managed_integration_groups))
  end

  defp managed_integration_catalog(_), do: []

  defp google_chat_service_account_fields do
    [
      {"Service account name", "Synaptic Assistant Chat Bot"},
      {"Service account ID", "synaptic-chat-bot (auto-fills from name)"},
      {"Description",
       "Service account for Synaptic Assistant to send messages in Google Chat spaces"}
    ]
  end
end
