defmodule AssistantWeb.Components.SettingsPage.Admin do
  # Settings page admin section component.
  # Renders the allow list management, user card grid, user detail view,
  # and admin-only model management (providers + role defaults).
  @moduledoc false

  use AssistantWeb, :html

  import AssistantWeb.Components.SettingsPage.UserCards, only: [user_cards_section: 1]
  import AssistantWeb.Components.SettingsPage.UserDetail, only: [user_detail_section: 1]

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
          No admin accounts exist yet. Claim admin access for your account to unlock the admin UI.
        </p>
      </div>
      <.button id="claim-admin-btn" phx-click="claim_bootstrap_admin">
        Claim Admin Access
      </.button>
    </section>

    <section :if={@current_scope.settings_user.is_admin} class="space-y-6">
      <.admin_model_providers {assigns} />
      <.admin_role_defaults {assigns} />

      <div class="sa-card">
        <div>
          <h2>Allow List</h2>
          <p>
            When at least one active entry exists, only active allow-listed emails can authenticate.
          </p>
        </div>

        <.form
          for={@allowlist_form}
          id="allowlist-entry-form"
          phx-change="validate_allowlist_entry"
          phx-submit="save_allowlist_entry"
          class="space-y-4"
          style="margin-top: 1rem;"
        >
          <div>
            <label for="allowlist-email" class="block text-sm font-medium mb-1">Email</label>
            <input
              id="allowlist-email"
              name={@allowlist_form[:email].name}
              type="email"
              value={@allowlist_form[:email].value}
              class="w-full rounded-md border border-zinc-300 px-3 py-2"
              required
            />
            <p
              :for={msg <- (@allowlist_form[:email] && @allowlist_form[:email].errors) || []}
              class="mt-1 text-xs text-red-600"
            >
              {translate_error(msg)}
            </p>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
            <label class="inline-flex items-center gap-2 text-sm">
              <input
                id="allowlist-active"
                type="checkbox"
                name={@allowlist_form[:active] && @allowlist_form[:active].name}
                value="true"
                checked={checkbox_checked?(@allowlist_form[:active] && @allowlist_form[:active].value)}
              /> Active
            </label>

            <label class="inline-flex items-center gap-2 text-sm">
              <input
                id="allowlist-admin"
                type="checkbox"
                name={@allowlist_form[:is_admin] && @allowlist_form[:is_admin].name}
                value="true"
                checked={checkbox_checked?(@allowlist_form[:is_admin] && @allowlist_form[:is_admin].value)}
              /> Admin access
            </label>
          </div>

          <div>
            <p class="block text-sm font-medium mb-2">Scoped Privileges</p>
            <input type="hidden" name="allowlist_entry[scopes][]" value="" />
            <div class="grid gap-2 sm:grid-cols-2">
              <label
                :for={scope <- @managed_scopes}
                class="inline-flex items-center gap-2 text-sm rounded border border-zinc-200 px-3 py-2"
              >
                <input
                  type="checkbox"
                  name="allowlist_entry[scopes][]"
                  value={scope}
                  checked={scope in form_scopes(@allowlist_form)}
                />
                <span>{scope}</span>
              </label>
            </div>
          </div>

          <div>
            <label for="allowlist-notes" class="block text-sm font-medium mb-1">Notes</label>
            <textarea
              id="allowlist-notes"
              name={@allowlist_form[:notes] && @allowlist_form[:notes].name}
              rows="3"
              class="w-full rounded-md border border-zinc-300 px-3 py-2"
            ><%= (@allowlist_form[:notes] && @allowlist_form[:notes].value) || "" %></textarea>
            <p
              :for={msg <- (@allowlist_form[:notes] && @allowlist_form[:notes].errors) || []}
              class="mt-1 text-xs text-red-600"
            >
              {translate_error(msg)}
            </p>
          </div>

          <div class="flex flex-wrap gap-3">
            <.button id="save-allowlist-entry-btn" phx-disable-with="Saving...">
              Save Allow List Entry
            </.button>
            <button
              id="reset-allowlist-entry-form-btn"
              type="button"
              phx-click="reset_allowlist_form"
              class="rounded-md border border-zinc-300 px-3 py-2 text-sm"
            >
              Clear Form
            </button>
          </div>
        </.form>
      </div>

      <div class="sa-card">
        <div>
          <h2>Allow List Entries</h2>
          <p>
            Edit entries to grant/revoke access and keep current user privileges in sync.
          </p>
        </div>

        <div class="overflow-x-auto" style="margin-top: 1rem;">
          <table class="min-w-full text-sm" id="allowlist-entries-table">
            <thead>
              <tr class="text-left border-b">
                <th class="py-2 pr-4">Email</th>
                <th class="py-2 pr-4">Status</th>
                <th class="py-2 pr-4">Admin</th>
                <th class="py-2 pr-4">Scopes</th>
                <th class="py-2 pr-4">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@allowlist_entries == []}>
                <td class="py-3 text-zinc-500" colspan="5">No allow list entries yet.</td>
              </tr>
              <tr
                :for={entry <- @allowlist_entries}
                id={"allowlist-entry-#{entry.id}"}
                class="border-b last:border-0"
              >
                <td class="py-2 pr-4">{entry.email}</td>
                <td class="py-2 pr-4">{if entry.active, do: "Active", else: "Disabled"}</td>
                <td class="py-2 pr-4">{if entry.is_admin, do: "Yes", else: "No"}</td>
                <td class="py-2 pr-4">{Enum.join(entry.scopes || [], ", ")}</td>
                <td class="py-2 pr-4">
                  <div class="flex flex-wrap gap-2">
                    <button
                      type="button"
                      phx-click="edit_allowlist_entry"
                      phx-value-id={entry.id}
                      class="rounded border border-zinc-300 px-2 py-1"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_allowlist_entry"
                      phx-value-id={entry.id}
                      class="rounded border border-zinc-300 px-2 py-1"
                    >
                      {if entry.active, do: "Disable", else: "Enable"}
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <.user_detail_section
        :if={@current_admin_user}
        user={@current_admin_user}
        current_user_id={@current_scope.settings_user.id}
      />

      <.user_cards_section
        :if={!@current_admin_user}
        users={@filtered_admin_users}
        search_value={@admin_user_search}
        current_user_id={@current_scope.settings_user.id}
      />
    </section>
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
            <div class="sa-model-default-select">
              <.field
                type="select"
                name={"defaults[#{role.key}]"}
                label={"Default model for #{role.label}"}
                label_class="sr-only"
                no_margin={true}
                options={@model_options}
                selected={Map.get(@model_defaults, Atom.to_string(role.key))}
                prompt="Select model"
              />
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

  defp form_scopes(form) do
    case form[:scopes] do
      nil -> []
      field -> field.value |> List.wrap() |> Enum.filter(&(&1 not in ["", nil]))
    end
  end

  defp checkbox_checked?(value), do: value in [true, "true", "on", 1]
end
