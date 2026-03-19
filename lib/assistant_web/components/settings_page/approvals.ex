defmodule AssistantWeb.Components.SettingsPage.Approvals do
  @moduledoc false

  use AssistantWeb, :html

  def approvals_section(assigns) do
    ~H"""
    <section class="sa-card">
      <div class="sa-row" style="justify-content: space-between; gap: 1rem;">
        <div>
          <h2>Approvals</h2>
          <p class="sa-text-muted">Pending actions that require user or admin approval.</p>
        </div>
        <span class="sa-badge sa-badge-info">
          {if @policy_api_available, do: "#{length(@policy_approvals || [])} pending", else: "Pending: n/a"}
        </span>
      </div>

      <div :if={!@policy_api_available} class="sa-card">
        <p class="sa-text-muted" style="margin: 0;">Approval inbox is not available yet.</p>
      </div>

      <div :if={@policy_api_available and @policy_approvals == []} class="sa-card">
        <p class="sa-text-muted" style="margin: 0;">Nothing needs approval right now.</p>
      </div>

      <article
        :if={@policy_api_available}
        :for={approval <- @policy_approvals}
        class="sa-card sa-approval-card"
        style="border-left: 4px solid var(--sa-surface-border);"
      >
        <div class="sa-row" style="gap: 1rem;">
          <div style="flex: 1;">
            <p class="sa-approval-label">
              <strong>{approval.title || approval.skill || approval.action || "Action"}</strong>
            </p>
            <p class="sa-approval-meta">
              {if approval.summary, do: approval.summary, else: approval.details}
            </p>
            <p class="sa-approval-meta" style="margin-top: 0.25rem;">
              <span class="sa-badge sa-badge-muted">
                {approval.source_label || "Sub-agent"}
              </span>
              <span class="sa-badge sa-badge-muted">
                {approval.user_label || "User"}
              </span>
            </p>
          </div>
          <div class="sa-row sa-approval-actions">
            <button
              type="button"
              class="sa-btn primary"
              phx-click="resolve_approval"
              phx-value-id={approval.id}
              phx-value-effect="allow"
            >
              Approve once
            </button>
            <button
              type="button"
              class="sa-btn secondary"
              phx-click="resolve_approval"
              phx-value-id={approval.id}
              phx-value-effect="ask"
            >
              Ask again
            </button>
            <button
              type="button"
              class="sa-btn danger"
              phx-click="resolve_approval"
              phx-value-id={approval.id}
              phx-value-effect="deny"
            >
              Deny
            </button>
          </div>
        </div>
      </article>
    </section>
    """
  end
end
