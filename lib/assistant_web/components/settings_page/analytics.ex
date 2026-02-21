defmodule AssistantWeb.Components.SettingsPage.Analytics do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  def analytics_section(assigns) do
    ~H"""
    <div class="sa-card-grid">
      <article class="sa-stat-card">
        <h3>Total Cost (7d)</h3>
        <p>${Float.round(@analytics_snapshot.total_cost, 2)}</p>
      </article>
      <article class="sa-stat-card">
        <h3>Prompt Tokens</h3>
        <p>{@analytics_snapshot.prompt_tokens}</p>
      </article>
      <article class="sa-stat-card">
        <h3>Completion Tokens</h3>
        <p>{@analytics_snapshot.completion_tokens}</p>
      </article>
      <article class="sa-stat-card">
        <h3>Tool Hits</h3>
        <p>{@analytics_snapshot.tool_hits}</p>
      </article>
      <article class="sa-stat-card">
        <h3>Failures</h3>
        <p>{@analytics_snapshot.failures}</p>
      </article>
      <article class="sa-stat-card">
        <h3>Failure Rate</h3>
        <p>{@analytics_snapshot.failure_rate}%</p>
      </article>

      <article class="sa-card">
        <h2>Top Tool Hits</h2>
        <div :if={@analytics_snapshot.top_tools == []} class="sa-muted">No tool activity yet.</div>
        <ul :if={@analytics_snapshot.top_tools != []} class="sa-simple-list">
          <li :for={tool <- @analytics_snapshot.top_tools}>
            <span>{tool.tool_name}</span>
            <strong>{tool.count}</strong>
          </li>
        </ul>
      </article>

      <article class="sa-card">
        <h2>Recent Failures</h2>
        <div :if={@analytics_snapshot.recent_failures == []} class="sa-muted">
          No failures recorded in the selected window.
        </div>
        <ul :if={@analytics_snapshot.recent_failures != []} class="sa-simple-list">
          <li :for={failure <- @analytics_snapshot.recent_failures}>
            <span>{failure.target}</span>
            <span>{Helpers.format_time(failure.occurred_at)}</span>
          </li>
        </ul>
      </article>
    </div>
    """
  end
end
