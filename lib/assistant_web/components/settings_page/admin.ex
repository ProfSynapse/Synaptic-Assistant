defmodule AssistantWeb.Components.SettingsPage.Admin do
  # Settings page admin section component.
  # Renders the allow list management, user card grid, and user detail view.
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

  defp form_scopes(form) do
    case form[:scopes] do
      nil -> []
      field -> field.value |> List.wrap() |> Enum.filter(&(&1 not in ["", nil]))
    end
  end

  defp checkbox_checked?(value), do: value in [true, "true", "on", 1]
end
