defmodule AssistantWeb.WorkflowEditorLive do
  use AssistantWeb, :live_view

  alias Assistant.Workflows

  @weekday_options [
    {"Sunday", "0"},
    {"Monday", "1"},
    {"Tuesday", "2"},
    {"Wednesday", "3"},
    {"Thursday", "4"},
    {"Friday", "5"},
    {"Saturday", "6"}
  ]

  @recurrence_options [
    {"Daily", "daily"},
    {"Weekly", "weekly"},
    {"Monthly", "monthly"},
    {"Custom", "custom"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:workflow, nil)
     |> assign(:weekday_options, @weekday_options)
     |> assign(:recurrence_options, @recurrence_options)
     |> assign(:tools, Workflows.available_tools())
     |> assign(:meta_form, to_form(%{}, as: :workflow))}
  end

  @impl true
  def handle_params(%{"name" => name}, _uri, socket) do
    case Workflows.get_workflow(name) do
      {:ok, workflow} ->
        {:noreply, assign(socket, :workflow, workflow)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workflow not found")
         |> push_navigate(to: ~p"/settings/workflows")}
    end
  end

  @impl true
  def handle_event("save_metadata", %{"workflow" => params}, socket) do
    socket = notify_autosave(socket, "saving", "Saving workflow settings...")

    case Workflows.update_metadata(socket.assigns.workflow.name, params) do
      {:ok, workflow} ->
        {:noreply,
         socket
         |> assign(:workflow, workflow)
         |> notify_autosave("saved", "All changes saved")}

      {:error, reason} ->
        {:noreply,
         socket
         |> notify_autosave("error", "Could not save workflow settings")
         |> put_flash(:error, "Failed to save workflow metadata: #{inspect(reason)}")}
    end
  end

  def handle_event("autosave_body", %{"body" => body}, socket) do
    socket = notify_autosave(socket, "saving", "Saving workflow...")

    case Workflows.update_body(socket.assigns.workflow.name, body) do
      {:ok, workflow} ->
        {:noreply,
         socket |> assign(:workflow, workflow) |> notify_autosave("saved", "All changes saved")}

      {:error, reason} ->
        {:noreply,
         socket
         |> notify_autosave("error", "Could not save workflow")
         |> put_flash(:error, "Failed to save workflow body: #{inspect(reason)}")}
    end
  end

  def handle_event("reload_scheduler", _params, socket) do
    case Assistant.Scheduler.QuantumLoader.reload() do
      :ok -> {:noreply, put_flash(socket, :info, "Scheduler reloaded")}
      _ -> {:noreply, put_flash(socket, :error, "Failed to reload scheduler")}
    end
  end

  defp notify_autosave(socket, state, message) do
    push_event(socket, "autosave:status", %{state: state, message: message})
  end

  defp recurrence(assigns), do: assigns.workflow.schedule.recurrence
  defp schedule_time(assigns), do: assigns.workflow.schedule.time
  defp day_of_week(assigns), do: assigns.workflow.schedule.day_of_week
  defp day_of_month(assigns), do: assigns.workflow.schedule.day_of_month
  defp custom_cron(assigns), do: assigns.workflow.schedule.custom_cron

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section :if={is_nil(@workflow)} class="sa-content sa-editor-page">
        <div class="sa-card">Loading workflow...</div>
      </section>

      <section :if={not is_nil(@workflow)} class="sa-content sa-editor-page">
        <header class="sa-row">
          <h1>Workflow Editor</h1>
          <div class="sa-row">
            <.link navigate={~p"/settings/workflows"} class="sa-btn secondary">Back to Workflows</.link>
            <button type="button" class="sa-btn secondary" phx-click="reload_scheduler">Reload Scheduler Now</button>
          </div>
        </header>

        <.form
          for={@meta_form}
          id="workflow-meta-form"
          phx-change="save_metadata"
          class="sa-card"
        >
          <.input name="workflow[description]" label="Description" value={@workflow.description} />

          <div class="sa-schedule-row">
            <.input
              type="select"
              name="workflow[recurrence]"
              label="Schedule"
              options={@recurrence_options}
              value={recurrence(assigns)}
            />
            <.input name="workflow[time]" type="time" label="Time" value={schedule_time(assigns)} />
            <.input
              :if={recurrence(assigns) == "weekly"}
              type="select"
              name="workflow[day_of_week]"
              label="Day"
              options={@weekday_options}
              value={day_of_week(assigns)}
            />
            <.input
              :if={recurrence(assigns) == "monthly"}
              type="text"
              name="workflow[day_of_month]"
              label="Day of Month"
              value={day_of_month(assigns)}
            />
            <.input
              :if={recurrence(assigns) == "custom"}
              type="text"
              name="workflow[custom_cron]"
              label="Custom Cron"
              value={custom_cron(assigns)}
            />
          </div>

          <.input name="workflow[channel]" label="Channel" value={@workflow.channel} />

          <section class="sa-tool-permissions">
            <h2>Tools</h2>
            <p>Select the tools this workflow is allowed to use.</p>
            <div class="sa-tool-grid">
              <label :for={tool <- @tools} class="sa-tool-item">
                <input
                  type="checkbox"
                  name="workflow[allowed_tools][]"
                  value={tool.id}
                  checked={tool.id in @workflow.allowed_tools}
                />
                <span>{tool.label}</span>
              </label>
            </div>
          </section>
        </.form>

        <section class="sa-card">
          <.editor_toolbar target="workflow-editor-canvas" label="Workflow markdown formatting" />

          <div
            id="workflow-editor-canvas"
            class="sa-editor-canvas"
            contenteditable="true"
            role="textbox"
            aria-multiline="true"
            aria-label="Workflow body"
            phx-hook="WorkflowRichEditor"
            phx-update="ignore"
            data-save-event="autosave_body"
          ><%= Phoenix.HTML.raw(@workflow.body_html) %></div>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
