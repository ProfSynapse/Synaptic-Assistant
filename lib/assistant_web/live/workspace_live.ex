defmodule AssistantWeb.WorkspaceLive do
  use AssistantWeb, :live_view

  alias Assistant.Workspace
  alias AssistantWeb.Components.WorkspaceFeed
  alias AssistantWeb.Components.SettingsPage.Helpers
  alias AssistantWeb.SettingsLive.Context

  @refresh_interval_ms 2_500
  @message_limit 200
  @message_limit_step 200

  @impl true
  def mount(_params, _session, socket) do
    user_id = resolve_workspace_user_id(socket)

    socket =
      socket
      |> assign(:sidebar_collapsed, false)
      |> assign(:section, "workspace")
      |> assign(:is_admin, current_scope_is_admin(socket.assigns[:current_scope]))
      |> assign(:workspace_user_id, user_id)
      |> assign(:conversation, nil)
      |> assign(:feed_items, [])
      |> assign(:tool_index, %{})
      |> assign(:sub_agent_index, %{})
      |> assign(:message_count, 0)
      |> assign(:history_truncated?, false)
      |> assign(:message_limit, @message_limit)
      |> assign(:composer_form, composer_form(""))
      |> assign(:sending, false)
      |> assign(:selected_inspect_type, nil)
      |> assign(:selected_inspect_id, nil)
      |> assign(:selected_inspect_data, nil)
      |> assign(:mission_expanded, false)
      |> maybe_load_workspace()

    if connected?(socket) and is_binary(user_id) do
      :timer.send_interval(@refresh_interval_ms, :refresh_feed)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"composer" => %{"message" => raw_message}}, socket) do
    message = raw_message |> to_string() |> String.trim()
    conversation = socket.assigns.conversation

    cond do
      message == "" ->
        {:noreply, socket}

      socket.assigns.sending ->
        {:noreply, socket}

      is_nil(conversation) or is_nil(socket.assigns.workspace_user_id) ->
        {:noreply, put_flash(socket, :error, "No linked conversation is available.")}

      true ->
        user_id = socket.assigns.workspace_user_id
        conversation_id = conversation.id

        socket =
          socket
          |> assign(:sending, true)
          |> assign(:composer_form, composer_form(""))
          |> start_async(:send_message, fn ->
            Workspace.send_message(user_id, conversation_id, message)
          end)

        {:noreply, socket}
    end
  end

  def handle_event("inspect_tool", %{"id" => inspect_id}, socket) do
    case Workspace.tool_detail(socket.assigns.tool_index, inspect_id) do
      nil ->
        {:noreply, socket}

      detail ->
        {:noreply, set_selected_inspect(socket, :tool, inspect_id, detail)}
    end
  end

  def handle_event("inspect_sub_agent", %{"id" => inspect_id}, socket) do
    conversation = socket.assigns.conversation

    detail =
      if conversation do
        Workspace.sub_agent_detail(conversation.id, socket.assigns.sub_agent_index, inspect_id)
      else
        nil
      end

    case detail do
      nil ->
        {:noreply, socket}

      sub_agent_detail ->
        {:noreply, set_selected_inspect(socket, :sub_agent, inspect_id, sub_agent_detail)}
    end
  end

  def handle_event("toggle_mission", _params, socket) do
    {:noreply, assign(socket, :mission_expanded, !socket.assigns.mission_expanded)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, clear_selected_inspect(socket)}
  end

  def handle_event("close_slide_over", _params, socket) do
    {:noreply, clear_selected_inspect(socket)}
  end

  def handle_event("load_older", _params, socket) do
    {:noreply,
     socket
     |> assign(:message_limit, socket.assigns.message_limit + @message_limit_step)
     |> maybe_load_workspace()}
  end

  @impl true
  def handle_info(:refresh_feed, socket) do
    {:noreply, maybe_load_workspace(socket)}
  end

  @impl true
  def handle_async(:send_message, {:ok, {:ok, _response}}, socket) do
    Process.send_after(self(), :refresh_feed, 350)

    {:noreply,
     socket
     |> assign(:sending, false)
     |> maybe_load_workspace()}
  end

  def handle_async(:send_message, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:sending, false)
     |> put_flash(:error, "Message failed: #{format_reason(reason)}")}
  end

  def handle_async(:send_message, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:sending, false)
     |> put_flash(:error, "Message failed: #{format_reason(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sa-settings-shell">
        <aside class={["sa-sidebar", @sidebar_collapsed && "is-collapsed"]}>
          <div class="sa-sidebar-header">
            <div class="sa-sidebar-brand">
              <img src="/images/aperture.png" alt="Synaptic Assistant" class="sa-brand-mark" />
              <span :if={!@sidebar_collapsed}>Synaptic Assistant</span>
            </div>
            <button
              type="button"
              class="sa-icon-btn sa-sidebar-toggle"
              phx-click="toggle_sidebar"
              aria-label="Toggle sidebar"
            >
              <.icon name="hero-bars-3" class="h-4 w-4" />
            </button>
          </div>

          <nav class="sa-sidebar-nav">
            <.link
              :for={{section, label} <- Helpers.nav_items_for(@is_admin)}
              navigate={nav_path(section)}
              class={["sa-sidebar-link", section == @section && "is-active"]}
              title={label}
            >
              <.icon name={Helpers.icon_for(section)} class="h-4 w-4" />
              <span :if={!@sidebar_collapsed}>{label}</span>
            </.link>
          </nav>

          <div class="sa-sidebar-footer">
            <form method="post" action={~p"/settings_users/log-out"}>
              <input type="hidden" name="_method" value="delete" />
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <button type="submit" class="sa-sidebar-link" title="Log Out">
                <.icon name="hero-arrow-right-on-rectangle" class="h-4 w-4" />
                <span :if={!@sidebar_collapsed}>Log Out</span>
              </button>
            </form>
          </div>
        </aside>

        <section class="sa-content">
          <section class="sa-workspace-shell">
            <header class="sa-workspace-header">
              <div>
                <h1>Synaptic Assistant</h1>
                <p>One ongoing chat across in-app and connected channels.</p>
              </div>
            </header>

            <section class="sa-workspace-feed-wrap">
              <div :if={@history_truncated?} class="sa-workspace-history-actions">
                <button type="button" class="sa-workspace-load-older-btn" phx-click="load_older">
                  Load older messages
                </button>
              </div>

              <p :if={@history_truncated?} class="sa-workspace-history-hint">
                Showing the newest conversation events. Older history is still available.
              </p>

              <div id="workspace-feed" class="sa-workspace-feed" phx-hook="ScrollToBottom">
                <div :if={@feed_items == []} class="sa-workspace-empty-state">
                  <p>Start chatting. Messages from connected channels will appear here too.</p>
                </div>

                <WorkspaceFeed.workspace_feed_items items={@feed_items} inspect_actions={true} />
              </div>
            </section>

            <footer class="sa-workspace-composer-wrap">
              <.form
                for={@composer_form}
                id="workspace-composer-form"
                class="sa-workspace-composer-form"
                phx-submit="send_message"
                phx-hook="WorkspaceComposer"
              >
                <.input
                  field={@composer_form[:message]}
                  type="textarea"
                  rows="1"
                  class="sa-workspace-composer-input"
                  placeholder="Message Synaptic across your connected channels..."
                  enterkeyhint="send"
                  autocomplete="off"
                  disabled={@sending}
                />
                <.icon_button
                  type="submit"
                  size="md"
                  radius="full"
                  color="primary"
                  loading={@sending}
                  disabled={@sending}
                  class="sa-workspace-send-btn"
                >
                  <.icon name="hero-arrow-up" class="h-4 w-4" />
                </.icon_button>
              </.form>
            </footer>
          </section>
        </section>
      </div>

      <div :if={@selected_inspect_data} class="sa-workspace-desktop-modal">
        <.modal id="workspace-inspect-modal" title={inspect_title(@selected_inspect_type, @selected_inspect_data)}>
          <.workspace_inspect_body
            type={@selected_inspect_type}
            data={@selected_inspect_data}
            mission_expanded={@mission_expanded}
          />
        </.modal>
      </div>

      <div :if={@selected_inspect_data} class="sa-workspace-mobile-modal">
        <.slide_over
          id="workspace-inspect-slideover"
          title={inspect_title(@selected_inspect_type, @selected_inspect_data)}
          origin="right"
          max_width="full"
        >
          <.workspace_inspect_body
            type={@selected_inspect_type}
            data={@selected_inspect_data}
            mission_expanded={@mission_expanded}
          />
        </.slide_over>
      </div>
    </Layouts.app>
    """
  end

  attr :type, :atom, required: true
  attr :data, :map, required: true
  attr :mission_expanded, :boolean, default: false

  def workspace_inspect_body(assigns) do
    ~H"""
    <div :if={@type == :tool} class="sa-workspace-inspect-stack">
      <div class="sa-detail-grid">
        <div class="sa-detail-item">
          <span class="sa-detail-label">Tool</span>
          <span class="sa-detail-value">{@data.name}</span>
        </div>
        <div class="sa-detail-item">
          <span class="sa-detail-label">Status</span>
          <span class="sa-detail-value">{status_label(@data.status)}</span>
        </div>
        <div class="sa-detail-item">
          <span class="sa-detail-label">Tool Call ID</span>
          <span class="sa-detail-value">{@data.tool_call_id}</span>
        </div>
      </div>

      <section class="sa-workspace-inspect-section">
        <h4>Arguments</h4>
        <pre class="sa-workspace-code"><%= if present?(@data.arguments_pretty), do: @data.arguments_pretty, else: "{}" %></pre>
      </section>

      <section class="sa-workspace-inspect-section">
        <h4>Result</h4>
        <pre class="sa-workspace-code"><%= if present?(@data.result_content), do: @data.result_content, else: "Result not persisted yet." %></pre>
      </section>
    </div>

    <div :if={@type == :sub_agent} class="sa-workspace-inspect-stack">
      <div class="sa-detail-grid">
        <div class="sa-detail-item">
          <span class="sa-detail-label">Sub-agent</span>
          <span class="sa-detail-value">{@data.agent_id}</span>
        </div>
        <div class="sa-detail-item">
          <span class="sa-detail-label">Status</span>
          <span class="sa-detail-value">{status_label(@data.status)}</span>
        </div>
        <div :if={is_integer(@data.tool_calls_used)} class="sa-detail-item">
          <span class="sa-detail-label">Tool Calls Used</span>
          <span class="sa-detail-value">{@data.tool_calls_used}</span>
        </div>
        <div :if={is_integer(@data.duration_ms)} class="sa-detail-item">
          <span class="sa-detail-label">Duration</span>
          <span class="sa-detail-value">{format_duration(@data.duration_ms)}</span>
        </div>
      </div>

      <section class="sa-workspace-inspect-section">
        <button type="button" class="sa-workspace-mission-toggle" phx-click="toggle_mission">
          <.icon name={if(@mission_expanded, do: "hero-minus", else: "hero-plus")} class="h-4 w-4" />
          <span>{if(@mission_expanded, do: "Hide mission", else: "Show mission")}</span>
        </button>
        <pre :if={@mission_expanded} class="sa-workspace-code">{if(present?(@data.mission), do: @data.mission, else: "Mission text not persisted.")}</pre>
      </section>

      <section class="sa-workspace-inspect-section">
        <div class="sa-workspace-inspect-heading-row">
          <h4>Transcript</h4>
          <.badge size="sm" color={transcript_mode_color(@data.transcript_mode)} variant="soft">
            {transcript_mode_label(@data.transcript_mode)}
          </.badge>
        </div>
        <pre class="sa-workspace-code"><%= if present?(@data.transcript_text), do: @data.transcript_text, else: "No transcript available." %></pre>
      </section>

      <section :if={present?(@data.result_text)} class="sa-workspace-inspect-section">
        <h4>Result</h4>
        <pre class="sa-workspace-code">{@data.result_text}</pre>
      </section>
    </div>
    """
  end

  defp maybe_load_workspace(socket) do
    workspace_user_id = resolve_workspace_user_id(socket)
    socket = assign(socket, :workspace_user_id, workspace_user_id)

    case workspace_user_id do
      nil ->
        put_flash(socket, :error, "No linked user account found for chat.")

      user_id ->
        case Workspace.load(user_id, limit: socket.assigns.message_limit) do
          {:ok, data} ->
            socket
            |> assign(:conversation, data.conversation)
            |> assign(:feed_items, data.feed_items)
            |> assign(:tool_index, data.tool_index)
            |> assign(:sub_agent_index, data.sub_agent_index)
            |> assign(:message_count, data.message_count)
            |> assign(:history_truncated?, data.truncated?)
            |> maybe_refresh_selected_inspect()

          {:error, reason} ->
            put_flash(socket, :error, "Failed to load conversation: #{format_reason(reason)}")
        end
    end
  end

  defp maybe_refresh_selected_inspect(socket) do
    type = socket.assigns.selected_inspect_type
    inspect_id = socket.assigns.selected_inspect_id

    case {type, inspect_id, socket.assigns.conversation} do
      {nil, _, _} ->
        socket

      {:tool, inspect_id, _conversation} when is_binary(inspect_id) ->
        case Workspace.tool_detail(socket.assigns.tool_index, inspect_id) do
          nil -> clear_selected_inspect(socket)
          detail -> assign(socket, :selected_inspect_data, detail)
        end

      {:sub_agent, inspect_id, %{id: conversation_id}} when is_binary(inspect_id) ->
        case Workspace.sub_agent_detail(
               conversation_id,
               socket.assigns.sub_agent_index,
               inspect_id
             ) do
          nil -> clear_selected_inspect(socket)
          detail -> assign(socket, :selected_inspect_data, detail)
        end

      _ ->
        clear_selected_inspect(socket)
    end
  end

  defp set_selected_inspect(socket, type, inspect_id, detail) do
    socket
    |> assign(:selected_inspect_type, type)
    |> assign(:selected_inspect_id, inspect_id)
    |> assign(:selected_inspect_data, detail)
    |> assign(:mission_expanded, false)
  end

  defp clear_selected_inspect(socket) do
    socket
    |> assign(:selected_inspect_type, nil)
    |> assign(:selected_inspect_id, nil)
    |> assign(:selected_inspect_data, nil)
    |> assign(:mission_expanded, false)
  end

  defp current_scope_is_admin(%{settings_user: %{is_admin: true}}), do: true
  defp current_scope_is_admin(_), do: false

  defp nav_path("profile"), do: ~p"/settings"
  defp nav_path("workspace"), do: ~p"/workspace"
  defp nav_path(section), do: ~p"/settings/#{section}"

  defp resolve_workspace_user_id(socket) do
    case Context.current_settings_user(socket) do
      %{user_id: fallback_user_id} = settings_user ->
        case Context.ensure_linked_user(settings_user) do
          {:ok, user_id} when is_binary(user_id) -> user_id
          _ -> fallback_user_id
        end

      _ ->
        nil
    end
  end

  defp composer_form(message), do: to_form(%{"message" => message}, as: :composer)

  defp inspect_title(:tool, data), do: "Tool Run · #{data.name}"
  defp inspect_title(:sub_agent, data), do: "Sub-agent · #{data.agent_id}"
  defp inspect_title(_, _), do: "Inspect"

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

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(String.trim(status)) do
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

  defp transcript_mode_color(:live), do: "info"
  defp transcript_mode_color(:historical), do: "success"
  defp transcript_mode_color(:result), do: "gray"
  defp transcript_mode_color(:empty), do: "warning"
  defp transcript_mode_color(_), do: "gray"

  defp transcript_mode_label(:live), do: "Live"
  defp transcript_mode_label(:historical), do: "Historical"
  defp transcript_mode_label(:result), do: "Result Fallback"
  defp transcript_mode_label(:empty), do: "Unavailable"
  defp transcript_mode_label(_), do: "Unknown"

  defp format_duration(duration_ms) when is_integer(duration_ms) and duration_ms >= 1000 do
    seconds = duration_ms / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> "s"
  end

  defp format_duration(duration_ms) when is_integer(duration_ms), do: "#{duration_ms}ms"
  defp format_duration(_), do: "n/a"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
