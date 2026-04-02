defmodule AssistantWeb.Components.SettingsPage.Onboarding do
  @moduledoc false

  use AssistantWeb, :html

  @doc """
  Renders a "Getting Started" onboarding checklist card.

  Expects assigns:
    - `checklist_items`: list of `%{label: str, complete?: bool, link: str, action: str}`
    - `all_complete?`: boolean — true when every item is done
    - `onboarding_dismissed?`: boolean — true when user manually dismissed
  """
  def onboarding_checklist(assigns) do
    ~H"""
    <article
      :if={!@onboarding_dismissed? && !@all_complete?}
      class="sa-card sa-onboarding-card"
      aria-label="Getting started checklist"
    >
      <div class="sa-onboarding-header">
        <h2>
          <.icon name="hero-rocket-launch" class="h-5 w-5" /> Getting Started
        </h2>
        <button
          type="button"
          class="sa-btn secondary sa-btn-sm"
          phx-click="dismiss_onboarding"
          aria-label="Dismiss getting started checklist"
        >
          Dismiss
        </button>
      </div>

      <p class="sa-muted">
        Complete these steps to set up your workspace.
      </p>

      <ul class="sa-onboarding-list" role="list">
        <li
          :for={item <- @checklist_items}
          class={"sa-onboarding-item #{if item.complete?, do: "sa-onboarding-done"}"}
          aria-label={item.label}
          aria-checked={"#{item.complete?}"}
          role="listitem"
        >
          <span class="sa-onboarding-icon">
            <.icon
              :if={item.complete?}
              name="hero-check-circle"
              class="h-5 w-5 text-green-500"
            />
            <.icon
              :if={!item.complete?}
              name="hero-minus-circle"
              class="h-5 w-5 text-zinc-300"
            />
          </span>

          <span class="sa-onboarding-label">
            {item.label}
          </span>

          <.link
            :if={!item.complete?}
            navigate={item.link}
            class="sa-btn secondary sa-btn-sm"
          >
            {item.action}
          </.link>

          <span :if={item.complete?} class="sa-muted sa-onboarding-status">
            Done
          </span>
        </li>
      </ul>
    </article>
    """
  end
end
