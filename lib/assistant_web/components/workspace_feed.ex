defmodule AssistantWeb.Components.WorkspaceFeed do
  @moduledoc false

  use AssistantWeb, :html

  attr :items, :list, default: []
  attr :sequence, :boolean, default: false
  attr :context_open, :boolean, default: false
  attr :inspect_actions, :boolean, default: false

  def workspace_feed_items(assigns) do
    ~H"""
    <%= for item <- @items do %>
      <.workspace_feed_item
        item={item}
        sequence={@sequence}
        context_open={@context_open}
        inspect_actions={@inspect_actions}
      />
    <% end %>
    """
  end

  attr :item, :map, required: true
  attr :sequence, :boolean, default: false
  attr :context_open, :boolean, default: false
  attr :inspect_actions, :boolean, default: false

  def workspace_feed_item(assigns) do
    assigns =
      assigns
      |> assign(:item_type, Map.get(assigns.item, :type))
      |> assign(:streaming, Map.get(assigns.item, :streaming, false))
      |> assign(:tools, Map.get(assigns.item, :tools, []))
      |> assign(:sub_agents, Map.get(assigns.item, :sub_agents, []))

    ~H"""
    <%= cond do %>
      <% @item_type == :message -> %>
        <article
          class={[
            "sa-workspace-message",
            @item.role == :user && "is-user",
            @item.role == :assistant && "is-assistant",
            @streaming && "sa-cloud-streaming-message"
          ]}
          data-sequence-step={if(@sequence, do: true, else: nil)}
          data-step-type={if(@sequence, do: if(@streaming, do: "streaming", else: "message"), else: nil)}
        >
          <div class="sa-workspace-message-meta">
            <div class="sa-workspace-message-meta-left">
              <span class="sa-workspace-actor">{actor_label(@item.role)}</span>
            </div>
            <div class="sa-workspace-message-meta-right">
              <.channel_source
                channel={Map.get(@item, :source_channel)}
                label={Map.get(@item, :source_label)}
              />
              <span>{format_time(Map.get(@item, :inserted_at) || Map.get(@item, :time))}</span>
            </div>
          </div>
          <p class="sa-workspace-message-content">{@item.content}<span :if={@streaming} class="sa-cloud-inline-dots" aria-hidden="true"><span></span><span></span><span></span></span></p>
        </article>

      <% @item_type in [:space_context, :context] -> %>
        <details
          class="sa-space-context"
          open={if(@context_open || Map.get(@item, :open, false), do: true, else: nil)}
          data-sequence-step={if(@sequence, do: true, else: nil)}
          data-step-type={if(@sequence, do: "context", else: nil)}
        >
          <summary class="sa-space-context-summary">
            <.icon name="hero-chat-bubble-left-right" class="sa-space-context-icon" />
            <span class="sa-space-context-label">{Map.get(@item, :source_label)}</span>
            <span class="sa-space-context-sub-type">
              {space_context_sub_type_label(Map.get(@item, :sub_type))}
            </span>
            <span class="sa-space-context-time">
              {format_time(Map.get(@item, :inserted_at) || Map.get(@item, :time))}
            </span>
            <.icon name="hero-chevron-right" class="sa-space-context-chevron" />
          </summary>
          <p class="sa-space-context-content">{@item.content}</p>
        </details>

      <% @item_type == :tool -> %>
        <section
          class="sa-workspace-activity-stack sa-cloud-tool-activity"
          data-sequence-step={if(@sequence, do: true, else: nil)}
          data-step-type={if(@sequence, do: "tool", else: nil)}
        >
          <div class="pc-card sa-workspace-activity-card">
            <div class="pc-card__inner">
              <div class="sa-workspace-activity-title-row">
                <div>
                  <p class="sa-workspace-activity-kicker">Tools</p>
                  <h3>1 tool call</h3>
                </div>
                <span class="sa-workspace-time">{format_time(Map.get(@item, :time))}</span>
              </div>

              <div class="sa-workspace-inline-list">
                <article class="sa-workspace-inline-card">
                  <div class="sa-workspace-inline-copy">
                    <p class="sa-workspace-inline-title">{Map.get(@item, :name)}</p>
                    <p class="sa-workspace-inline-subtitle">{Map.get(@item, :detail)}</p>
                  </div>
                  <.badge
                    size="sm"
                    color={status_color(Map.get(@item, :status))}
                    variant="soft"
                    class="sa-cloud-tool-badge"
                  >
                    <span class="sa-cloud-tool-status-pending">
                      {tool_pending_label(@item)}<span class="sa-cloud-inline-dots" aria-hidden="true"><span></span><span></span><span></span></span>
                    </span>
                    <span class="sa-cloud-tool-status-final">{final_status_label(@item)}</span>
                  </.badge>
                </article>
              </div>
            </div>
          </div>
        </section>

      <% true -> %>
        <section class="sa-workspace-activity-stack">
          <div :if={@tools != []} class="pc-card sa-workspace-activity-card">
            <div class="pc-card__inner">
              <div class="sa-workspace-activity-title-row">
                <div>
                  <p class="sa-workspace-activity-kicker">Tools</p>
                  <h3>{tool_count_label(@tools)}</h3>
                </div>
                <span class="sa-workspace-time">
                  {format_time(Map.get(@item, :inserted_at) || Map.get(@item, :time))}
                </span>
              </div>

              <div class="sa-workspace-inline-list">
                <article :for={tool <- @tools} class="sa-workspace-inline-card">
                  <div class="sa-workspace-inline-copy">
                    <p class="sa-workspace-inline-title">{tool.name}</p>
                    <p :if={Map.get(tool, :detail)} class="sa-workspace-inline-subtitle">
                      {tool.detail}
                    </p>
                    <.badge size="sm" color={status_color(tool.status)} variant="soft">
                      {status_label(tool.status)}
                    </.badge>
                  </div>
                  <button
                    :if={@inspect_actions}
                    type="button"
                    class="sa-workspace-inspect-btn"
                    phx-click="inspect_tool"
                    phx-value-id={tool.inspect_id}
                    aria-label="Inspect"
                  >
                    <.icon name="hero-eye-solid" class="h-4 w-4" />
                  </button>
                </article>
              </div>
            </div>
          </div>

          <div :for={sub_agent <- @sub_agents} class="pc-card sa-workspace-activity-card">
            <div class="pc-card__inner">
              <div class="sa-workspace-activity-title-row">
                <div>
                  <p class="sa-workspace-activity-kicker">Sub-agent</p>
                  <h3>{sub_agent.agent_id}</h3>
                  <p class="sa-workspace-inline-subtitle">{mission_excerpt(sub_agent.mission)}</p>
                </div>
                <.badge size="sm" color={status_color(sub_agent.status)} variant="soft">
                  {status_label(sub_agent.status)}
                </.badge>
              </div>

              <div :if={@inspect_actions} class="sa-workspace-inline-actions">
                <button
                  type="button"
                  class="sa-workspace-inspect-btn"
                  phx-click="inspect_sub_agent"
                  phx-value-id={sub_agent.inspect_id}
                  aria-label="Inspect"
                >
                  <.icon name="hero-eye-solid" class="h-4 w-4" />
                </button>
              </div>
            </div>
          </div>
        </section>
    <% end %>
    """
  end

  attr :channel, :string, default: nil
  attr :label, :string, default: nil

  def channel_source(assigns) do
    assigns = assign(assigns, :icon_path, source_icon_path(assigns.channel))

    ~H"""
    <span :if={@icon_path || @label} class="sa-channel-source">
      <img :if={@icon_path} src={@icon_path} alt="" class="sa-channel-icon-image" />
      <span :if={@label} class="sa-channel-source-label">{@label}</span>
    </span>
    """
  end

  defp actor_label(:user), do: "You"
  defp actor_label(:assistant), do: "Synaptic"
  defp actor_label(_), do: "Synaptic"

  defp space_context_sub_type_label(:question), do: "asked"
  defp space_context_sub_type_label(:response), do: "responded"
  defp space_context_sub_type_label("question"), do: "asked"
  defp space_context_sub_type_label("response"), do: "responded"
  defp space_context_sub_type_label(label) when is_binary(label), do: label
  defp space_context_sub_type_label(_), do: ""

  defp tool_count_label([_single]), do: "1 tool call"
  defp tool_count_label(tools), do: "#{length(tools)} tool calls"

  defp mission_excerpt(mission) when is_binary(mission) do
    mission
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
    |> case do
      "" -> "Mission text not persisted."
      text -> text
    end
  end

  defp mission_excerpt(_), do: "Mission text not persisted."

  defp status_color(status) do
    case normalize_status(status) do
      :running -> "info"
      :awaiting_orchestrator -> "warning"
      :completed -> "success"
      :failed -> "danger"
      :timeout -> "danger"
      _ -> "gray"
    end
  end

  defp status_label(status) do
    case normalize_status(status) do
      :running -> "Running"
      :awaiting_orchestrator -> "Awaiting"
      :completed -> "Completed"
      :failed -> "Failed"
      :timeout -> "Timed Out"
      _ -> "Unknown"
    end
  end

  defp final_status_label(item) do
    Map.get(item, :status_label) || status_label(Map.get(item, :status))
  end

  defp tool_pending_label(item) do
    case normalize_status(Map.get(item, :status)) do
      :awaiting_orchestrator -> "Awaiting"
      _ -> "Running"
    end
  end

  defp normalize_status(:done), do: :completed
  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(String.trim(status)) do
      "done" -> :completed
      "running" -> :running
      "awaiting_orchestrator" -> :awaiting_orchestrator
      "awaiting" -> :awaiting_orchestrator
      "completed" -> :completed
      "failed" -> :failed
      "timeout" -> :timeout
      _ -> :unknown
    end
  end

  defp normalize_status(_), do: :unknown

  defp format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%-I:%M %p")
  end

  defp format_time(value) when is_binary(value), do: value
  defp format_time(_), do: ""

  defp source_icon_path("google_chat"), do: "/images/apps/google-chat.svg"
  defp source_icon_path("telegram"), do: "/images/apps/telegram.svg"
  defp source_icon_path("slack"), do: "/images/apps/slack.svg"
  defp source_icon_path("discord"), do: "/images/apps/discord.svg"
  defp source_icon_path("in_app"), do: "/images/aperture.png"
  defp source_icon_path(_), do: nil
end
