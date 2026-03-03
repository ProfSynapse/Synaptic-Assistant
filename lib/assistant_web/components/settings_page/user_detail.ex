defmodule AssistantWeb.Components.SettingsPage.UserDetail do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  attr :user, :map, required: true
  attr :current_user_id, :string, required: true

  def user_detail_section(assigns) do
    is_self = assigns.user.id == assigns.current_user_id
    assigns = assign(assigns, :is_self, is_self)

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
end
