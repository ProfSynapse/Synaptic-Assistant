defmodule AssistantWeb.Components.SettingsPage.Profile do
  @moduledoc false

  use AssistantWeb, :html

  alias Assistant.Deployment
  alias AssistantWeb.Components.SettingsPage.Helpers

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
            <.field
              name="profile[display_name]"
              label="Full Name"
              value={@profile["display_name"]}
              placeholder="Jane Doe"
              phx-debounce="500"
              no_margin
            />
            <.field
              type="email"
              name="profile[email]"
              label="Email"
              value={@profile["email"]}
              placeholder="jane@company.com"
              phx-debounce="500"
              no_margin
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

      <article class="sa-card">
        <h2>Workspace Billing</h2>
        <p class="sa-muted">
          Billing applies to the shared workspace account, not individual logins.
        </p>

        <div class="sa-detail-grid" style="margin-top: 1rem;">
          <div class="sa-detail-item">
            <span class="sa-detail-label">Workspace</span>
            <span class="sa-detail-value">{@billing_summary.account_name || "Workspace"}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Plan</span>
            <span class="sa-detail-value">{String.capitalize(@billing_summary.plan || "free")}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Active Seats</span>
            <span class="sa-detail-value">{@billing_summary.seat_count}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Subscription Status</span>
            <span class="sa-detail-value">
              {if @billing_summary.stripe_subscription_status,
                do: Helpers.humanize(@billing_summary.stripe_subscription_status),
                else: "Free"}
            </span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Billing Email</span>
            <span class="sa-detail-value">{@billing_summary.billing_email || "Not set"}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Current Period End</span>
            <span class="sa-detail-value">
              {if @billing_summary.current_period_end,
                do: Helpers.format_time(@billing_summary.current_period_end),
                else: "-"}
            </span>
          </div>
        </div>

        <div class="sa-detail-grid" style="margin-top: 1rem;">
          <div class="sa-detail-item">
            <span class="sa-detail-label">Included Storage</span>
            <span class="sa-detail-value">{@billing_storage.included_label}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Current Retained Storage</span>
            <span class="sa-detail-value">{@billing_storage.current_label}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Projected Overage</span>
            <span class="sa-detail-value">{@billing_storage.projected_overage_label}</span>
          </div>
          <div class="sa-detail-item">
            <span class="sa-detail-label">Billing Basis</span>
            <span class="sa-detail-value">Monthly average retained storage</span>
          </div>
        </div>

        <p class="sa-muted" style="margin-top: 1rem;">
          {@billing_storage.plan_note}
        </p>

        <p class="sa-muted" style="margin-top: 0.5rem;">
          Deleting content during the month lowers future average storage, but the charge is still
          based on average retained storage across the full billing month rather than whatever is
          left on the last day.
        </p>

        <p :if={Deployment.self_hosted?()} class="sa-muted" style="margin-top: 1rem;">
          This deployment is self-hosted, so Stripe checkout and the cloud pricing catalog are not shown here.
        </p>

        <div
          :if={Deployment.cloud?() && @billing_summary.can_manage? && @billing_summary.billing_mode == "standard"}
          class="sa-form-actions"
        >
          <form method="post" action={~p"/billing/checkout/pro"}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="sa-btn">Start Pro Checkout</button>
          </form>

          <form method="post" action={~p"/billing/portal"}>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="sa-btn secondary">Open Billing Portal</button>
          </form>
        </div>

        <p
          :if={Deployment.cloud?() && @billing_summary.can_manage? && @billing_summary.billing_mode != "standard"}
          class="sa-muted"
          style="margin-top: 1rem;"
        >
          This workspace is using an internal billing override. Switch back to standard billing to
          manage checkout or the Stripe portal.
        </p>

        <p :if={Deployment.cloud?() && !@billing_summary.can_manage?} class="sa-muted" style="margin-top: 1rem;">
          Billing changes are managed by a workspace billing admin.
        </p>

        <p :if={!@billing_storage.metering_available?} class="sa-muted" style="margin-top: 0.75rem;">
          Storage metering is not active yet, so usage figures will appear here once billing
          snapshots are running.
        </p>
      </article>
    </section>
    """
  end
end
