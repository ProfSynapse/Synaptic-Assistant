defmodule AssistantWeb.Components.SettingsPage.UserCards do
  @moduledoc false

  use AssistantWeb, :html

  import AssistantWeb.Components.SettingsPage.CardGrid, only: [card_grid: 1]

  attr :users, :list, required: true
  attr :search_value, :string, default: ""
  attr :current_user_id, :string, required: true

  def user_cards_section(assigns) do
    ~H"""
    <section class="sa-card">
      <div class="sa-row" style="justify-content: space-between; margin-bottom: 16px;">
        <h2 style="font-size: 1.25rem; font-weight: 600; color: var(--sa-text-main); margin: 0;">Users</h2>
      </div>

      <.card_grid
        id="user-cards"
        items={@users}
        search_value={@search_value}
        search_event="search_admin_users"
        search_placeholder="Search users by email or name..."
        empty_message="No users found."
      >
        <:card :let={users}>
          <article :for={user <- users} class="sa-workflow-card" id={"user-card-#{user.id}"}>
            <h3 style="margin: 0 0 4px 0; font-size: 0.9rem;">
              {user.email}
            </h3>
            <p :if={user.display_name} style="margin: 0 0 8px 0; font-size: 0.8rem; color: var(--sa-text-muted, #71717a);">
              {user.display_name}
            </p>

            <div style="display: flex; flex-wrap: wrap; gap: 4px; margin-bottom: 8px;">
              <span :if={user.is_admin} class="sa-badge sa-badge-info">Admin</span>
              <span :if={user.disabled_at} class="sa-badge sa-badge-danger">Disabled</span>
              <span :if={user.has_linked_user} class="sa-badge sa-badge-success">Linked</span>
              <span :if={user.has_openrouter_key} class="sa-badge sa-badge-success">OR Key</span>
              <span :if={user.has_openai_key} class="sa-badge sa-badge-success">OAI Key</span>
            </div>

            <div class="sa-row" style="margin-bottom: 8px;">
              <span>Enabled</span>
              <label class={["sa-switch", is_self?(user, @current_user_id) && "sa-switch-disabled"]}>
                <input
                  type="checkbox"
                  checked={!user.disabled_at}
                  class="sa-switch-input"
                  role="switch"
                  aria-checked={to_string(!user.disabled_at)}
                  aria-label={"Toggle #{user.email} enabled"}
                  phx-click="toggle_user_disabled"
                  phx-value-id={user.id}
                  disabled={is_self?(user, @current_user_id)}
                />
                <span class="sa-switch-slider"></span>
              </label>
            </div>

            <div class="sa-icon-row">
              <form
                :if={!is_self?(user, @current_user_id) && !user.disabled_at}
                method="post"
                action={~p"/settings_users/impersonate"}
                style="margin: 0; display: inline;"
              >
                <input type="hidden" name="id" value={user.id} />
                <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                <button type="submit" class="sa-icon-btn" title={"View as #{user.email}"}>
                  <.icon name="hero-eye" class="h-4 w-4" />
                </button>
              </form>
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
                class={["sa-icon-btn", is_self?(user, @current_user_id) && "sa-icon-btn-disabled"]}
                title="Delete User"
                phx-click="delete_admin_user"
                phx-value-id={user.id}
                data-confirm="Are you sure you want to delete this user? This action cannot be undone."
                disabled={is_self?(user, @current_user_id)}
              >
                <.icon name="hero-trash" class="h-4 w-4" />
              </button>
            </div>
          </article>
        </:card>
      </.card_grid>
    </section>
    """
  end

  defp is_self?(user, current_user_id), do: user.id == current_user_id
end
