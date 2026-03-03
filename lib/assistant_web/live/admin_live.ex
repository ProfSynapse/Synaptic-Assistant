defmodule AssistantWeb.AdminLive do
  use AssistantWeb, :live_view

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUserAllowlistEntry
  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Registry
  alias AssistantWeb.SettingsUserAuth

  import AssistantWeb.Components.AdminIntegrations

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:managed_scopes, Accounts.managed_access_scopes())
      |> assign(:can_bootstrap_admin, Accounts.admin_bootstrap_available?())

    current_user = socket.assigns.current_scope.settings_user

    cond do
      current_user.is_admin ->
        {:ok, load_admin_data(socket)}

      socket.assigns.can_bootstrap_admin ->
        {:ok,
         socket
         |> assign(:allowlist_form, blank_allowlist_form())
         |> assign(:allowlist_entries, [])
         |> assign(:settings_users, [])
         |> assign(:admin_users_with_keys, [])
         |> assign(:integration_settings, [])}

      true ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have permission to access admin.")
         |> push_navigate(to: ~p"/settings")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="mx-auto max-w-6xl p-6 space-y-8">
        <header class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 class="text-2xl font-semibold">Admin</h1>
            <p class="text-sm text-zinc-600">
              Manage the operator allow list, scoped privileges, and account recovery.
            </p>
          </div>
          <div class="flex gap-3">
            <.link navigate={~p"/settings"} class="text-sm underline">
              Back to Settings
            </.link>
          </div>
        </header>

        <section
          :if={!@current_scope.settings_user.is_admin and @can_bootstrap_admin}
          id="admin-bootstrap"
          class="rounded-lg border border-amber-300 bg-amber-50 p-4 space-y-3"
        >
          <div>
            <h2 class="font-semibold text-amber-900">Initial Admin Bootstrap</h2>
            <p class="text-sm text-amber-900/80">
              No admin accounts exist yet. Claim admin access for your account to unlock the admin UI.
            </p>
          </div>
          <.button id="claim-admin-btn" phx-click="claim_bootstrap_admin">
            Claim Admin Access
          </.button>
        </section>

        <section :if={@current_scope.settings_user.is_admin} class="grid gap-8 lg:grid-cols-[1.1fr_1fr]">
          <div class="space-y-8">
            <section class="rounded-lg border border-zinc-200 bg-white p-4 space-y-4">
              <div>
                <h2 class="font-semibold">Allow List</h2>
                <p class="text-sm text-zinc-600">
                  When at least one active entry exists, only active allow-listed emails can authenticate.
                </p>
              </div>

              <.form
                for={@allowlist_form}
                id="allowlist-entry-form"
                phx-change="validate_allowlist_entry"
                phx-submit="save_allowlist_entry"
                class="space-y-4"
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
                  <p :for={msg <- @allowlist_form[:email].errors} class="mt-1 text-xs text-red-600">
                    {translate_error(msg)}
                  </p>
                </div>

                <div class="grid gap-3 sm:grid-cols-2">
                  <label class="inline-flex items-center gap-2 text-sm">
                    <input
                      id="allowlist-active"
                      type="checkbox"
                      name={@allowlist_form[:active].name}
                      value="true"
                      checked={checkbox_checked?(@allowlist_form[:active].value)}
                    />
                    Active
                  </label>

                  <label class="inline-flex items-center gap-2 text-sm">
                    <input
                      id="allowlist-admin"
                      type="checkbox"
                      name={@allowlist_form[:is_admin].name}
                      value="true"
                      checked={checkbox_checked?(@allowlist_form[:is_admin].value)}
                    />
                    Admin access
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
                    name={@allowlist_form[:notes].name}
                    rows="3"
                    class="w-full rounded-md border border-zinc-300 px-3 py-2"
                  ><%= @allowlist_form[:notes].value %></textarea>
                  <p :for={msg <- @allowlist_form[:notes].errors} class="mt-1 text-xs text-red-600">
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
            </section>

            <section class="rounded-lg border border-zinc-200 bg-white p-4 space-y-4">
              <div>
                <h2 class="font-semibold">Allow List Entries</h2>
                <p class="text-sm text-zinc-600">
                  Edit entries to grant/revoke access and keep current user privileges in sync.
                </p>
              </div>

              <div class="overflow-x-auto">
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
                    <tr :for={entry <- @allowlist_entries} id={"allowlist-entry-#{entry.id}"} class="border-b last:border-0">
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
            </section>
          </div>

          <section class="rounded-lg border border-zinc-200 bg-white p-4 space-y-4">
            <div>
              <h2 class="font-semibold">Users</h2>
              <p class="text-sm text-zinc-600">
                Help users recover access by sending a magic link or forcing a password reset.
              </p>
            </div>

            <div class="overflow-x-auto">
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
                  <tr :if={@settings_users == []}>
                    <td class="py-3 text-zinc-500" colspan="4">No user accounts yet.</td>
                  </tr>
                  <tr :for={user <- @settings_users} id={"admin-user-#{user.id}"} class="border-b last:border-0">
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
          </section>
        </section>

        <section :if={@current_scope.settings_user.is_admin} class="space-y-4">
          <section class="rounded-lg border border-zinc-200 bg-white p-4 space-y-4">
            <div>
              <h2 class="font-semibold">User API Keys</h2>
              <p class="text-sm text-zinc-600">
                Provision per-user OpenRouter API keys. Users with a key will use it instead of the system key.
              </p>
            </div>

            <div class="overflow-x-auto">
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
                  <tr :for={user <- @admin_users_with_keys} id={"user-key-#{user.id}"} class="border-b last:border-0">
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
          </section>

          <div>
            <h2 class="text-xl font-semibold">Integrations</h2>
            <p class="text-sm text-zinc-600">
              Configure API keys and tokens for connected services.
              Values saved here override environment variables.
            </p>
          </div>
          <.admin_integrations settings={@integration_settings} />
        </section>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("claim_bootstrap_admin", _params, socket) do
    case Accounts.bootstrap_admin_access(socket.assigns.current_scope.settings_user) do
      {:ok, _settings_user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Admin access claimed.")
         |> reload_current_user_scope()
         |> load_admin_data()}

      {:error, :bootstrap_closed} ->
        {:noreply,
         socket
         |> put_flash(:error, "Admin bootstrap is no longer available.")
         |> push_navigate(to: ~p"/settings")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to claim admin access.")}
    end
  end

  def handle_event("validate_allowlist_entry", %{"allowlist_entry" => params}, socket) do
    form =
      %SettingsUserAllowlistEntry{}
      |> Accounts.change_settings_user_allowlist_entry(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "allowlist_entry")

    {:noreply, assign(socket, :allowlist_form, form)}
  end

  def handle_event("save_allowlist_entry", %{"allowlist_entry" => params}, socket) do
    case Accounts.upsert_settings_user_allowlist_entry(
           params,
           socket.assigns.current_scope.settings_user
         ) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> put_flash(:info, "Allow list entry saved.")
         |> reload_current_user_scope()
         |> load_admin_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :allowlist_form, to_form(changeset, as: "allowlist_entry"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to save allow list entry.")}
    end
  end

  def handle_event("reset_allowlist_form", _params, socket) do
    {:noreply, assign(socket, :allowlist_form, blank_allowlist_form())}
  end

  def handle_event("edit_allowlist_entry", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.allowlist_entries, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Allow list entry not found.")}

      entry ->
        {:noreply,
         assign(
           socket,
           :allowlist_form,
           to_form(Accounts.change_settings_user_allowlist_entry(entry), as: "allowlist_entry")
         )}
    end
  end

  def handle_event("toggle_allowlist_entry", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.allowlist_entries, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Allow list entry not found.")}

      entry ->
        params = %{
          email: entry.email,
          active: !entry.active,
          is_admin: entry.is_admin,
          scopes: entry.scopes,
          notes: entry.notes
        }

        case Accounts.upsert_settings_user_allowlist_entry(
               params,
               socket.assigns.current_scope.settings_user
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Allow list entry updated.")
             |> reload_current_user_scope()
             |> load_admin_data()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to update allow list entry.")}
        end
    end
  end

  def handle_event("send_recovery_link", %{"id" => id}, socket) do
    with %{} = user <- Enum.find(socket.assigns.settings_users, &(&1.id == id)),
         {:ok, _email} <-
           Accounts.admin_send_recovery_link(user, &url(~p"/settings_users/log-in/#{&1}")) do
      {:noreply, put_flash(socket, :info, "Recovery magic link sent to #{user.email}.")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "User is not currently allow-listed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to send recovery link.")}
    end
  end

  def handle_event("force_password_reset", %{"id" => id}, socket) do
    with %{} = user <- Enum.find(socket.assigns.settings_users, &(&1.id == id)),
         {:ok, _updated_user, expired_tokens, _email} <-
           Accounts.admin_force_password_reset(user, &url(~p"/settings_users/log-in/#{&1}")) do
      SettingsUserAuth.disconnect_sessions(expired_tokens)

      {:noreply, put_flash(socket, :info, "Password reset initiated for #{user.email}.")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "User is not currently allow-listed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to force password reset.")}
    end
  end

  def handle_event("save_integration", %{"key" => key, "value" => value}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      unless Registry.known_key?(key) do
        {:noreply, put_flash(socket, :error, "Unknown integration key.")}
      else
        value = String.trim(value)

        if value == "" do
          {:noreply, put_flash(socket, :error, "Value cannot be blank.")}
        else
          admin_id = socket.assigns.current_scope.settings_user.id

          case IntegrationSettings.put(String.to_existing_atom(key), value, admin_id) do
            {:ok, _setting} ->
              {:noreply,
               socket
               |> put_flash(:info, "Integration setting saved.")
               |> assign(:integration_settings, IntegrationSettings.list_all())}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Unable to save integration setting.")}
          end
        end
      end
    end
  end

  def handle_event("delete_integration", %{"key" => key}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      unless Registry.known_key?(key) do
        {:noreply, put_flash(socket, :error, "Unknown integration key.")}
      else
        case IntegrationSettings.delete(String.to_existing_atom(key)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Integration setting reverted to environment variable.")
             |> assign(:integration_settings, IntegrationSettings.list_all())}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to delete integration setting.")}
        end
      end
    end
  end

  def handle_event("save_user_openrouter_key", %{"user_id" => user_id, "api_key" => api_key}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      api_key = String.trim(api_key)

      if api_key == "" do
        {:noreply, put_flash(socket, :error, "API key cannot be blank.")}
      else
        case Accounts.admin_set_openrouter_key(user_id, api_key) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "OpenRouter API key saved.")
             |> assign(:admin_users_with_keys, Accounts.list_settings_users_for_admin())}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to save API key.")}
        end
      end
    end
  end

  def handle_event("delete_user_openrouter_key", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      case Accounts.admin_clear_openrouter_key(user_id) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "OpenRouter API key removed.")
           |> assign(:admin_users_with_keys, Accounts.list_settings_users_for_admin())}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to remove API key.")}
      end
    end
  end

  defp load_admin_data(socket) do
    assign(socket,
      can_bootstrap_admin: Accounts.admin_bootstrap_available?(),
      allowlist_form: blank_allowlist_form(),
      allowlist_entries: Accounts.list_settings_user_allowlist_entries(),
      settings_users: Accounts.list_admin_settings_users(),
      admin_users_with_keys: Accounts.list_settings_users_for_admin(),
      integration_settings: IntegrationSettings.list_all()
    )
  end

  defp blank_allowlist_form do
    %SettingsUserAllowlistEntry{}
    |> Accounts.change_settings_user_allowlist_entry(%{
      active: true,
      is_admin: false,
      scopes: []
    })
    |> to_form(as: "allowlist_entry")
  end

  defp form_scopes(form) do
    form[:scopes].value
    |> List.wrap()
    |> Enum.filter(&(&1 not in ["", nil]))
  end

  defp checkbox_checked?(value), do: value in [true, "true", "on", 1]

  defp reload_current_user_scope(socket) do
    current_user = Accounts.get_settings_user!(socket.assigns.current_scope.settings_user.id)
    assign(socket, :current_scope, Assistant.Accounts.Scope.for_settings_user(current_user))
  end
end
