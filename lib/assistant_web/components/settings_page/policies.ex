defmodule AssistantWeb.Components.SettingsPage.Policies do
  @moduledoc false

  use AssistantWeb, :html

  def policies_section(assigns) do
    ~H"""
    <section class="sa-card space-y-4">
      <div>
        <h2>Workspace Policies</h2>
        <p class="sa-text-muted">
          Pick a preset to control runtime behavior for outgoing actions and external writes.
          Admin overrides and per-action rules appear below.
        </p>
      </div>

      <form phx-submit="set_policy_preset" class="sa-policy-presets">
        <input type="hidden" name="preset" value={@policy_preset} />
        <div class="sa-row" style="gap: 0.5rem;">
          <button
            :for={preset <- @policy_preset_options}
            type="submit"
            name="preset"
            value={preset}
            class={["sa-btn secondary", preset == @policy_preset && "is-active"]}
          >
            {String.capitalize(preset)}
          </button>
        </div>
      </form>

      <div :if={!@policy_api_available} class="sa-card">
        <p class="sa-text-muted" style="margin: 0;">
          Policy management is not available yet.
        </p>
      </div>

      <div :if={@policy_api_available}>
        <h3>Active Rules</h3>
        <div :if={@policy_rules == []} class="sa-card">
          <p class="sa-text-muted" style="margin: 0;">No explicit rules configured yet.</p>
        </div>
        <ul :if={@policy_rules != []} class="sa-policy-rules">
          <li :for={rule <- @policy_rules} class="sa-policy-rule">
            <div class="sa-row" style="justify-content: space-between;">
              <div>
                <p class="sa-policy-rule-title">
                  {rule.summary || rule.name || "#{rule.resource_type} rule"}
                </p>
                <p class="sa-text-muted">
                  {rule.effect || "allow"} · {rule.matchers |> inspect()}
                </p>
              </div>
              <span
                class={{
                  "sa-badge",
                  rule.effect == "allow" && "sa-badge-success",
                  rule.effect == "ask" && "sa-badge-warning",
                  rule.effect == "deny" && "sa-badge-danger"
                }}
              >
                {String.capitalize(rule.effect || "allow")}
              </span>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end
end
