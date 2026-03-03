defmodule AssistantWeb.Components.SettingsPage.Admin do
  # Settings page admin section component.
  # Renders the allow list management and user management panels.
  # Ported from AdminLive — integration settings are handled separately in the Apps tab.
  @moduledoc false

  use AssistantWeb, :html

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

      <div class="sa-card">
        <div>
          <h2>Users</h2>
          <p>
            Help users recover access by sending a magic link or forcing a password reset.
          </p>
        </div>

        <div class="overflow-x-auto" style="margin-top: 1rem;">
          <table class="min-w-full text-sm" id="admin-users-table">
            <thead>
              <tr class="text-left border-b">
                <th class="py-2 pr-4">Email</th>
                <th class="py-2 pr-4">Admin</th>
                <th class="py-2 pr-4">Scopes</th>
                <th class="py-2 pr-4">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@admin_settings_users == []}>
                <td class="py-3 text-zinc-500" colspan="4">No user accounts yet.</td>
              </tr>
              <tr
                :for={user <- @admin_settings_users}
                id={"admin-user-#{user.id}"}
                class="border-b last:border-0"
              >
                <td class="py-2 pr-4">{user.email}</td>
                <td class="py-2 pr-4">{if user.is_admin, do: "Yes", else: "No"}</td>
                <td class="py-2 pr-4">{Enum.join(user.access_scopes || [], ", ")}</td>
                <td class="py-2 pr-4">
                  <div class="flex flex-wrap gap-2">
                    <button
                      type="button"
                      phx-click="send_recovery_link"
                      phx-value-id={user.id}
                      class="rounded border border-zinc-300 px-2 py-1"
                    >
                      Send Magic Link
                    </button>
                    <button
                      type="button"
                      phx-click="force_password_reset"
                      phx-value-id={user.id}
                      class="rounded border border-zinc-300 px-2 py-1"
                    >
                      Force Password Reset
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="sa-card">
        <div>
          <h2>User API Keys</h2>
          <p>
            Provision per-user OpenRouter API keys. Users with a key will use it instead of the system key.
          </p>
        </div>

        <div class="overflow-x-auto" style="margin-top: 1rem;">
          <table class="min-w-full text-sm" id="admin-user-keys-table">
            <thead>
              <tr class="text-left border-b">
                <th class="py-2 pr-4">User</th>
                <th class="py-2 pr-4">Chat Account</th>
                <th class="py-2 pr-4">OpenRouter Key</th>
                <th class="py-2 pr-4">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@admin_users_with_keys == []}>
                <td class="py-3 text-zinc-500" colspan="4">No user accounts yet.</td>
              </tr>
              <tr
                :for={user <- @admin_users_with_keys}
                id={"user-key-#{user.id}"}
                class="border-b last:border-0"
              >
                <td class="py-2 pr-4">
                  <div>
                    <span class="font-medium">{user.email}</span>
                    <span :if={user.display_name} class="text-zinc-500 text-xs ml-1">
                      ({user.display_name})
                    </span>
                  </div>
                </td>
                <td class="py-2 pr-4">
                  <span
                    :if={user.has_linked_user}
                    class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700"
                  >
                    Linked
                  </span>
                  <span
                    :if={!user.has_linked_user}
                    class="inline-flex items-center rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-500"
                  >
                    Not Linked
                  </span>
                </td>
                <td class="py-2 pr-4">
                  <span
                    :if={user.has_openrouter_key}
                    class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700"
                  >
                    Configured
                  </span>
                  <span
                    :if={!user.has_openrouter_key}
                    class="inline-flex items-center rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-500"
                  >
                    Not Set
                  </span>
                </td>
                <td class="py-2 pr-4">
                  <div class="flex flex-wrap items-center gap-2">
                    <form
                      phx-submit="save_user_openrouter_key"
                      id={"user-key-form-#{user.id}"}
                      class="flex items-center gap-2"
                    >
                      <input type="hidden" name="user_id" value={user.id} />
                      <input
                        type="password"
                        name="api_key"
                        placeholder={if user.has_openrouter_key, do: "Replace key...", else: "sk-or-v1-..."}
                        autocomplete="off"
                        class="rounded-md border border-zinc-300 px-2 py-1 text-sm font-mono w-40"
                      />
                      <button
                        type="submit"
                        class="rounded-md bg-zinc-800 px-2 py-1 text-xs font-medium text-white hover:bg-zinc-700"
                      >
                        Save
                      </button>
                    </form>
                    <button
                      :if={user.has_openrouter_key}
                      type="button"
                      phx-click="delete_user_openrouter_key"
                      phx-value-id={user.id}
                      class="rounded border border-red-300 px-2 py-1 text-xs text-red-600 hover:bg-red-50"
                      data-confirm="Remove this user's OpenRouter API key?"
                    >
                      Remove Key
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp form_scopes(form) do
    case form[:scopes] do
      nil -> []
      field -> field.value |> List.wrap() |> Enum.filter(&(&1 not in ["", nil]))
    end
  end

  defp checkbox_checked?(value), do: value in [true, "true", "on", 1]
end
