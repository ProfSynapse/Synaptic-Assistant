defmodule AssistantWeb.Components.SettingsPage.UserDetail do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  attr :allowlist_form, :any, required: true
  attr :managed_scopes, :list, required: true

  def user_create_section(assigns) do
    selected_scopes =
      List.wrap(assigns.allowlist_form[:scopes] && assigns.allowlist_form[:scopes].value)

    assigns = assign(assigns, :selected_scopes, selected_scopes)

    ~H"""
    <section class="space-y-6">
      <div class="sa-card">
        <div class="sa-row" style="justify-content: space-between; margin-bottom: 16px;">
          <div>
            <button
              type="button"
              phx-click="back_to_admin_users"
              class="sa-icon-btn"
              title="Back to Users"
              style="margin-right: 8px;"
            >
              <.icon name="hero-arrow-left" class="h-4 w-4" />
            </button>
            <span style="font-size: 1.25rem; font-weight: 600; color: var(--sa-text-main);">
              Add User
            </span>
          </div>
        </div>

        <.form
          for={@allowlist_form}
          id="create-user-form"
          phx-change="validate_allowlist_entry"
          phx-submit="save_allowlist_entry"
        >
          <div class="sa-detail-grid" style="margin-bottom: 24px;">
            <div class="sa-detail-item">
              <.field
                type="email"
                field={@allowlist_form[:email]}
                label="Email"
                placeholder="user@example.com"
                required
                no_margin
              />
            </div>
          </div>

          <h3 style="font-size: 1.1rem; font-weight: 600; margin: 0 0 16px 0;">Account Controls</h3>

          <div class="sa-row" style="margin-bottom: 16px;">
            <div>
              <span style="font-weight: 500;">Active</span>
              <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 2px 0 0 0;">
                Inactive users cannot log in.
              </p>
            </div>
            <label class="sa-switch">
              <input
                type="checkbox"
                name={@allowlist_form[:active] && @allowlist_form[:active].name}
                value="true"
                class="sa-switch-input"
                role="switch"
                checked={checkbox_checked?(@allowlist_form[:active] && @allowlist_form[:active].value)}
                aria-label="Toggle active status"
              />
              <span class="sa-switch-slider"></span>
            </label>
          </div>

          <div class="sa-row" style="margin-bottom: 24px;">
            <div>
              <span style="font-weight: 500;">Admin</span>
              <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 2px 0 0 0;">
                Grant admin privileges to manage workspace settings.
              </p>
            </div>
            <label class="sa-switch">
              <input
                type="checkbox"
                name={@allowlist_form[:is_admin] && @allowlist_form[:is_admin].name}
                value="true"
                class="sa-switch-input"
                role="switch"
                checked={checkbox_checked?(@allowlist_form[:is_admin] && @allowlist_form[:is_admin].value)}
                aria-label="Toggle admin status"
              />
              <span class="sa-switch-slider"></span>
            </label>
          </div>

          <h3 style="font-size: 1.1rem; font-weight: 600; margin: 0 0 16px 0;">Scoped Privileges</h3>
          <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 0 0 12px 0;">
            Select which features this user can access.
          </p>

          <input type="hidden" name="allowlist_entry[scopes][]" value="" />
          <div style="display: flex; flex-wrap: wrap; gap: 1rem; margin-bottom: 24px;">
            <label :for={scope <- @managed_scopes} class="sa-switch" style="display: flex; align-items: center; gap: 0.5rem;">
              <input
                type="checkbox"
                name="allowlist_entry[scopes][]"
                value={scope}
                class="sa-switch-input"
                role="switch"
                checked={scope in @selected_scopes}
                aria-label={"Toggle #{scope} access"}
              />
              <span class="sa-switch-slider"></span>
              <span style="font-size: 0.875rem; text-transform: capitalize;">{scope}</span>
            </label>
          </div>

          <div style="display: flex; gap: 0.75rem;">
            <.button id="save-new-user-btn" phx-disable-with="Saving...">
              Create User
            </.button>
            <button
              type="button"
              phx-click="back_to_admin_users"
              class="sa-btn secondary"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  attr :user, :map, required: true
  attr :current_user_id, :string, required: true

  def user_detail_section(assigns) do
    is_self = assigns.user.id == assigns.current_user_id
    model_defaults_toggle_disabled = assigns.user.is_admin

    assigns =
      assigns
      |> assign(:is_self, is_self)
      |> assign(:model_defaults_toggle_disabled, model_defaults_toggle_disabled)

    ~H"""
    <section class="space-y-6">
      <div class="sa-card">
        <div class="sa-row" style="justify-content: space-between; margin-bottom: 16px;">
          <div>
            <button
              type="button"
              phx-click="back_to_admin_users"
              class="sa-icon-btn"
              title="Back to Users"
              style="margin-right: 8px;"
            >
              <.icon name="hero-arrow-left" class="h-4 w-4" />
            </button>
            <span style="font-size: 1.25rem; font-weight: 600; color: var(--sa-text-main);">
              {@user.email}
            </span>
          </div>
          <div style="display: flex; gap: 4px;">
            <span :if={@user.is_admin} class="sa-badge sa-badge-info">Admin</span>
            <span :if={@user.disabled_at} class="sa-badge sa-badge-danger">Disabled</span>
            <span :if={@user.has_linked_user} class="sa-badge sa-badge-success">Linked</span>
          </div>
        </div>

        <div class="sa-detail-grid">
          <div class="sa-detail-item">
            <span class="sa-detail-label">Display Name</span>
            <span class="sa-detail-value">{@user.display_name || "Not set"}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Email</span>
            <span class="sa-detail-value">{@user.email}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Confirmed At</span>
            <span class="sa-detail-value">{Helpers.format_time(@user.confirmed_at)}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Created At</span>
            <span class="sa-detail-value">{Helpers.format_time(@user.inserted_at)}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Updated At</span>
            <span class="sa-detail-value">{Helpers.format_time(@user.updated_at)}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Chat Account</span>
            <span class="sa-detail-value">
              {if @user.has_linked_user, do: "Linked (#{Helpers.short_id(@user.user_id)})", else: "Not Linked"}
            </span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Access Scopes</span>
            <span class="sa-detail-value">
              {if @user.access_scopes && @user.access_scopes != [], do: Enum.join(@user.access_scopes, ", "), else: "None"}
            </span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Model Defaults Scope</span>
            <span class="sa-detail-value">
              {model_defaults_scope_label(@user)}
            </span>
          </div>
        </div>
      </div>

      <div class="sa-card">
        <h3 style="font-size: 1.1rem; font-weight: 600; margin: 0 0 16px 0;">Account Controls</h3>

        <div class="sa-row" style="margin-bottom: 16px;">
          <div>
            <span style="font-weight: 500;">Admin Status</span>
            <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 2px 0 0 0;">
              Grant or revoke admin privileges.
            </p>
          </div>
          <label class={["sa-switch", @is_self && "sa-switch-disabled"]}>
            <input
              type="checkbox"
              checked={@user.is_admin}
              class="sa-switch-input"
              role="switch"
              aria-checked={to_string(@user.is_admin)}
              aria-label={"Toggle admin for #{@user.email}"}
              phx-click="toggle_admin_status"
              phx-value-id={@user.id}
              phx-value-is-admin={to_string(!@user.is_admin)}
              disabled={@is_self}
            />
            <span class="sa-switch-slider"></span>
          </label>
        </div>

        <div class="sa-row" style="margin-bottom: 16px;">
          <div>
            <span style="font-weight: 500;">Account Enabled</span>
            <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 2px 0 0 0;">
              Disabled users cannot log in.
            </p>
          </div>
          <label class={["sa-switch", @is_self && "sa-switch-disabled"]}>
            <input
              type="checkbox"
              checked={!@user.disabled_at}
              class="sa-switch-input"
              role="switch"
              aria-checked={to_string(!@user.disabled_at)}
              aria-label={"Toggle #{@user.email} enabled"}
              phx-click="toggle_user_disabled"
              phx-value-id={@user.id}
              disabled={@is_self}
            />
            <span class="sa-switch-slider"></span>
          </label>
        </div>

        <div class="sa-row" style="margin-bottom: 0;">
          <div>
            <span style="font-weight: 500;">Can Manage Personal Model Defaults</span>
            <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 2px 0 0 0;">
              When enabled, this user can edit the user-specific defaults below from their own settings page.
            </p>
            <p :if={@model_defaults_toggle_disabled} style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 4px 0 0 0;">
              Admin accounts always manage the app-wide defaults instead of personal overrides.
            </p>
          </div>
          <label class={["sa-switch", @model_defaults_toggle_disabled && "sa-switch-disabled"]}>
            <input
              type="checkbox"
              checked={@user.can_manage_model_defaults}
              class="sa-switch-input"
              role="switch"
              aria-checked={to_string(@user.can_manage_model_defaults)}
              aria-label={"Toggle personal model defaults for #{@user.email}"}
              phx-click="toggle_user_model_defaults_access"
              phx-value-id={@user.id}
              phx-value-enabled={to_string(!@user.can_manage_model_defaults)}
              disabled={@model_defaults_toggle_disabled}
            />
            <span class="sa-switch-slider"></span>
          </label>
        </div>
      </div>

      <div class="sa-card">
        <h3 style="font-size: 1.1rem; font-weight: 600; margin: 0 0 8px 0;">User Model Defaults</h3>
        <p class="sa-muted" style="margin: 0 0 16px 0;">{@user.model_defaults_description}</p>

        <div :if={@user.is_admin} class="sa-empty">
          Admin accounts use the shared app-wide defaults configured on the Models page.
        </div>

        <.form
          :if={!@user.is_admin}
          for={to_form(@user.effective_model_defaults || %{}, as: :admin_defaults)}
          id={"admin-user-model-defaults-form-#{@user.id}"}
          phx-change="change_admin_user_model_defaults"
          class="sa-model-defaults-form"
        >
          <input type="hidden" name="user_id" value={@user.id} />

          <div class="sa-model-defaults-grid">
            <div :for={role <- @user.model_default_roles} class="sa-model-default-row">
              <div class="sa-model-default-meta">
                <div class="sa-model-default-title">
                  <span class="sa-model-default-role">{role.label}</span>
                  <span class="sa-muted" style="font-size: 0.8rem;">
                    {admin_model_default_source_label(@user.model_default_sources, role.key)}
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

              <div class="sa-model-default-select">
                <.field
                  type="select"
                  name={"defaults[#{role.key}]"}
                  label={"Default model for #{role.label}"}
                  label_class="sr-only"
                  no_margin={true}
                  options={@user.model_options}
                  selected={Map.get(@user.effective_model_defaults || %{}, Atom.to_string(role.key))}
                  prompt="Select model"
                  disabled={!@user.model_defaults_editable}
                />
              </div>
            </div>
          </div>

          <div class="sa-row" style="margin-top: 16px; align-items: center;">
            <p class="sa-muted" style="margin: 0; flex: 1;">{@user.model_defaults_notice}</p>
            <button
              :if={@user.model_defaults_resettable}
              type="button"
              phx-click="apply_global_admin_user_model_defaults"
              phx-value-id={@user.id}
              class="sa-btn secondary"
              data-confirm="Clear this user's overrides and apply the global defaults instead?"
            >
              Apply Global Defaults
            </button>
          </div>
        </.form>
      </div>

      <div class="sa-card">
        <h3 style="font-size: 1.1rem; font-weight: 600; margin: 0 0 16px 0;">API Keys</h3>

        <div style="margin-bottom: 16px;">
          <div class="sa-row" style="margin-bottom: 8px;">
            <span style="font-weight: 500;">OpenRouter API Key</span>
            <span :if={@user.has_openrouter_key} class="sa-badge sa-badge-success">Configured</span>
            <span :if={!@user.has_openrouter_key} class="sa-badge">Not Set</span>
          </div>

          <form
            phx-submit="save_admin_user_openrouter_key"
            id={"admin-user-key-form-#{@user.id}"}
            class="sa-row"
            style="gap: 8px;"
          >
            <input type="hidden" name="user_id" value={@user.id} />
            <input
              type="password"
              name="api_key"
              placeholder={if @user.has_openrouter_key, do: "Replace key...", else: "sk-or-v1-..."}
              autocomplete="off"
              class="sa-input"
              style="flex: 1; max-width: 300px; font-family: monospace;"
            />
            <button
              type="submit"
              class="sa-btn sa-btn-sm"
            >
              Save
            </button>
            <button
              :if={@user.has_openrouter_key}
              type="button"
              phx-click="delete_admin_user_openrouter_key"
              phx-value-id={@user.id}
              class="sa-btn sa-btn-sm sa-btn-danger"
              data-confirm="Remove this user's OpenRouter API key?"
            >
              Remove
            </button>
          </form>
        </div>

        <div>
          <div class="sa-row">
            <span style="font-weight: 500;">OpenAI API Key</span>
            <span :if={@user.has_openai_key} class="sa-badge sa-badge-success">Configured</span>
            <span :if={!@user.has_openai_key} class="sa-badge">Not Set</span>
          </div>
          <p style="font-size: 0.8rem; color: var(--sa-text-muted, #71717a); margin: 4px 0 0 0;">
            OpenAI keys are managed by the user via OAuth or manual entry.
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp model_defaults_scope_label(%{is_admin: true}), do: "App-wide admin"

  defp model_defaults_scope_label(%{can_manage_model_defaults: true, model_defaults: overrides})
       when map_size(overrides) > 0 do
    "User-managed (#{map_size(overrides)} override#{if map_size(overrides) == 1, do: "", else: "s"})"
  end

  defp model_defaults_scope_label(%{can_manage_model_defaults: true}), do: "User-managed"

  defp model_defaults_scope_label(%{model_defaults: overrides}) when map_size(overrides) > 0 do
    "Admin-managed (#{map_size(overrides)} override#{if map_size(overrides) == 1, do: "", else: "s"})"
  end

  defp model_defaults_scope_label(_), do: "Global only"

  defp checkbox_checked?(value), do: value in [true, "true", "on", 1]

  defp admin_model_default_source_label(source_map, role_key) do
    case Map.get(source_map || %{}, Atom.to_string(role_key), :system) do
      :user -> "User-specific override"
      :global -> "Global default"
      :system -> "System fallback"
    end
  end
end
