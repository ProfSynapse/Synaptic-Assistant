defmodule AssistantWeb.Components.SettingsPage.Skills do
  @moduledoc false

  use AssistantWeb, :html

  def skills_section(assigns) do
    ~H"""
    <section class="sa-card">
      <p class="sa-muted">Toggle runtime permissions by Domain and Skill name.</p>

      <div :if={@skills_permissions == []} class="sa-empty">
        No registered skills were found.
      </div>

      <table :if={@skills_permissions != []} class="sa-table">
        <thead>
          <tr>
            <th>Domain</th>
            <th>Skill</th>
            <th>Enabled</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={perm <- @skills_permissions}>
            <td>{perm.domain_label}</td>
            <td>{perm.skill_label}</td>
            <td>
              <label class="sa-switch">
                <input
                  type="checkbox"
                  checked={perm.enabled}
                  class="sa-switch-input"
                  role="switch"
                  aria-checked={to_string(perm.enabled)}
                  aria-label={"Toggle #{perm.skill_label}"}
                  phx-click="toggle_skill_permission"
                  phx-value-skill={perm.id}
                  phx-value-enabled={to_string(!perm.enabled)}
                />
                <span class="sa-switch-slider"></span>
              </label>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
