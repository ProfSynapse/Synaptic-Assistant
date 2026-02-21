defmodule AssistantWeb.Components.SettingsPage.Workflows do
  @moduledoc false

  use AssistantWeb, :html

  def workflows_section(assigns) do
    ~H"""
    <section class="sa-card">
      <div class="sa-row">
        <h2>Workflow Cards</h2>
        <button class="sa-btn" type="button" phx-click="new_workflow">
          <.icon name="hero-plus" class="h-4 w-4" /> New Workflow
        </button>
      </div>

      <div :if={@workflows == []} class="sa-empty">
        No workflows found. Create one with `workflow.create`, then manage it here.
      </div>

      <div :if={@workflows != []} class="sa-workflow-grid">
        <article :for={workflow <- @workflows} class="sa-workflow-card">
          <h3>{workflow.name}</h3>
          <div class="sa-row">
            <span>Enabled</span>
            <label class="sa-switch">
              <input
                type="checkbox"
                checked={workflow.enabled}
                class="sa-switch-input"
                role="switch"
                aria-checked={to_string(workflow.enabled)}
                aria-label={"Toggle #{workflow.name}"}
                phx-click="toggle_workflow_enabled"
                phx-value-name={workflow.name}
                phx-value-enabled={to_string(!workflow.enabled)}
              />
              <span class="sa-switch-slider"></span>
            </label>
          </div>
          <p>{workflow.schedule_label}</p>
          <div class="sa-icon-row">
            <.link
              navigate={~p"/settings/workflows/#{workflow.name}/edit"}
              class="sa-icon-btn"
              title="Edit Workflow"
            >
              <.icon name="hero-pencil-square" class="h-4 w-4" />
            </.link>
            <button
              type="button"
              class="sa-icon-btn"
              title="Duplicate Workflow"
              phx-click="duplicate_workflow"
              phx-value-name={workflow.name}
            >
              <.icon name="hero-document-duplicate" class="h-4 w-4" />
            </button>
          </div>
        </article>
      </div>
    </section>
    """
  end
end
