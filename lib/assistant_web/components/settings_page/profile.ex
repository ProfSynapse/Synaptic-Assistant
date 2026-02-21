defmodule AssistantWeb.Components.SettingsPage.Profile do
  @moduledoc false

  use AssistantWeb, :html

  def profile_section(assigns) do
    ~H"""
    <section class="sa-section-stack">
      <article class="sa-card">
        <h2>Account</h2>
        <p class="sa-muted">Manage your profile and account settings.</p>

        <.form
          for={@profile_form}
          as={:profile}
          id="profile-form"
          phx-change="autosave_profile"
          phx-hook="ProfileTimezone"
        >
          <div class="sa-profile-grid">
            <.input
              name="profile[display_name]"
              label="Full Name"
              value={@profile["display_name"]}
              placeholder="Jane Doe"
              phx-debounce="500"
            />
            <.input
              type="email"
              name="profile[email]"
              label="Email"
              value={@profile["email"]}
              placeholder="jane@company.com"
              phx-debounce="500"
            />
          </div>
          <input
            id="profile-timezone-input"
            type="hidden"
            name="profile[timezone]"
            value={@profile["timezone"]}
          />

          <div class="sa-form-actions">
            <.link navigate={~p"/settings_users/settings"} class="sa-btn secondary">
              Change Password
            </.link>
          </div>
        </.form>
      </article>

      <article class="sa-card">
        <h2>Orchestrator System Prompt</h2>
        <p class="sa-muted">
          Tune personality and preferences. This is injected into the orchestrator system prompt.
        </p>

        <.editor_toolbar target="orchestrator-editor-canvas" label="Orchestrator prompt formatting" />

        <div
          id="orchestrator-editor-canvas"
          class="sa-editor-canvas sa-system-prompt-input"
          contenteditable="true"
          role="textbox"
          aria-multiline="true"
          aria-label="Orchestrator system prompt"
          phx-hook="WorkflowRichEditor"
          phx-update="ignore"
          data-save-event="autosave_orchestrator_prompt"
        ><%= Phoenix.HTML.raw(@orchestrator_prompt_html) %></div>
      </article>
    </section>
    """
  end
end
