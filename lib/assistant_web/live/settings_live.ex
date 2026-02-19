defmodule AssistantWeb.SettingsLive do
  use AssistantWeb, :live_view

  alias Assistant.Analytics
  alias Assistant.ModelCatalog
  alias Assistant.SkillPermissions
  alias Assistant.Workflows

  @sections ~w(general models analytics apps workflows skills help)

  @app_catalog [
    %{
      id: "google_workspace",
      name: "Google Workspace",
      scopes: "Gmail, Calendar, Drive",
      summary: "Connect approved Google tools for email, calendars, and docs."
    },
    %{
      id: "hubspot",
      name: "HubSpot",
      scopes: "Contacts, Deals",
      summary: "Sync CRM tasks and account updates from HubSpot."
    },
    %{
      id: "slack",
      name: "Slack",
      scopes: "Channels, DMs",
      summary: "Read channel context and post workflow notifications."
    }
  ]

  @help_articles [
    %{
      slug: "google-workspace",
      title: "Google Workspace Setup",
      summary: "Connect Gmail, Calendar, and Drive with approved scopes.",
      body: [
        "Open Apps & Connections and click Add App.",
        "Choose Google Workspace from the catalog.",
        "Approve requested scopes and verify connection health."
      ]
    },
    %{
      slug: "models-setup",
      title: "Models Setup",
      summary: "Review active models and keep input/output pricing current.",
      body: [
        "Open Models and review active roster entries.",
        "Confirm input and output cost values for each model.",
        "Set role defaults in config so orchestrator flows stay aligned."
      ]
    },
    %{
      slug: "workflow-guide",
      title: "Workflow Guide",
      summary: "Create card-based workflows and edit in rendered markdown mode.",
      body: [
        "Create or duplicate workflows from the Workflows page.",
        "Open the workflow editor and write content in rendered mode.",
        "Use schedule and tool permissions to scope runtime behavior."
      ]
    },
    %{
      slug: "skill-permissions",
      title: "Skill Permissions Guide",
      summary: "Enable or disable skills using user-friendly labels.",
      body: [
        "Go to Skill Permissions and toggle by Domain and Skill.",
        "Disabled skills are blocked at runtime for sub-agents and memory agent.",
        "Use this to enforce operational boundaries, such as disabling Send Email."
      ]
    }
  ]

  @empty_analytics %{
    window_days: 7,
    total_cost: 0.0,
    prompt_tokens: 0,
    completion_tokens: 0,
    total_tokens: 0,
    tool_hits: 0,
    llm_calls: 0,
    failures: 0,
    failure_rate: 0.0,
    top_tools: [],
    recent_failures: []
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:sidebar_collapsed, false)
     |> assign(:section, "general")
     |> assign(:workflows, [])
     |> assign(:models, [])
     |> assign(:model_modal_open, false)
     |> assign(
       :model_form,
       to_form(%{"id" => "", "name" => "", "input_cost" => "", "output_cost" => ""}, as: :model)
     )
     |> assign(:analytics_snapshot, @empty_analytics)
     |> assign(:apps_modal_open, false)
     |> assign(:app_catalog, @app_catalog)
     |> assign(:skills_permissions, [])
     |> assign(:help_articles, @help_articles)
     |> assign(:help_topic, nil)
     |> assign(:help_query, "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = normalize_section(Map.get(params, "section", "general"))
    help_topic = Map.get(params, "topic")

    socket =
      socket
      |> assign(:section, section)
      |> assign(:help_topic, selected_help_article(section, help_topic))
      |> load_section_data(section)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_workflow_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case Workflows.set_enabled(name, enabled?) do
      {:ok, _workflow} ->
        {:noreply, reload_workflows(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle workflow: #{inspect(reason)}")}
    end
  end

  def handle_event("duplicate_workflow", %{"name" => name}, socket) do
    case Workflows.duplicate(name) do
      {:ok, copied} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created copy: #{copied.name}")
         |> reload_workflows()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to duplicate workflow: #{inspect(reason)}")}
    end
  end

  def handle_event("open_add_app_modal", _params, socket) do
    {:noreply, assign(socket, :apps_modal_open, true)}
  end

  def handle_event("close_add_app_modal", _params, socket) do
    {:noreply, assign(socket, :apps_modal_open, false)}
  end

  def handle_event("add_catalog_app", %{"id" => app_id}, socket) do
    app_name =
      @app_catalog
      |> Enum.find(&(&1.id == app_id))
      |> case do
        nil -> "App"
        app -> app.name
      end

    {:noreply,
     socket
     |> assign(:apps_modal_open, false)
     |> put_flash(:info, "#{app_name} added to your approved app connections list.")}
  end

  def handle_event("open_model_modal", params, socket) do
    model_id = Map.get(params, "id")

    model =
      case model_id do
        nil -> %{"id" => "", "name" => "", "input_cost" => "", "output_cost" => ""}
        "" -> %{"id" => "", "name" => "", "input_cost" => "", "output_cost" => ""}
        id -> model_to_form_data(id)
      end

    {:noreply,
     socket
     |> assign(:model_modal_open, true)
     |> assign(:model_form, to_form(model, as: :model))}
  end

  def handle_event("close_model_modal", _params, socket) do
    {:noreply, assign(socket, :model_modal_open, false)}
  end

  def handle_event("save_model", %{"model" => params}, socket) do
    case ModelCatalog.upsert_model(params) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> assign(:model_modal_open, false)
         |> load_models()
         |> put_flash(:info, "Model catalog saved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save model: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_skill_permission", %{"skill" => skill, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case SkillPermissions.set_enabled(skill, enabled?) do
      :ok ->
        {:noreply,
         socket
         |> load_skill_permissions()
         |> put_flash(:info, "#{SkillPermissions.skill_label(skill)} updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update permission: #{inspect(reason)}")}
    end
  end

  def handle_event("search_help", %{"help" => %{"q" => query}}, socket) do
    {:noreply, assign(socket, :help_query, query)}
  end

  defp load_section_data(socket, "workflows"), do: reload_workflows(socket)
  defp load_section_data(socket, "models"), do: load_models(socket)
  defp load_section_data(socket, "analytics"), do: load_analytics(socket)
  defp load_section_data(socket, "skills"), do: load_skill_permissions(socket)
  defp load_section_data(socket, _section), do: socket

  defp reload_workflows(socket) do
    case Workflows.list_workflows() do
      {:ok, workflows} -> assign(socket, :workflows, workflows)
      {:error, _reason} -> assign(socket, :workflows, [])
    end
  end

  defp load_models(socket) do
    assign(socket, :models, ModelCatalog.list_models())
  end

  defp load_analytics(socket) do
    snapshot = Analytics.dashboard_snapshot(window_days: 7)
    assign(socket, :analytics_snapshot, snapshot)
  rescue
    _ ->
      assign(socket, :analytics_snapshot, @empty_analytics)
  end

  defp load_skill_permissions(socket) do
    assign(socket, :skills_permissions, SkillPermissions.list_permissions())
  end

  defp normalize_section(section) when section in @sections, do: section
  defp normalize_section(_), do: "general"

  defp selected_help_article("help", nil), do: nil

  defp selected_help_article("help", slug) do
    Enum.find(@help_articles, &(&1.slug == slug))
  end

  defp selected_help_article(_, _), do: nil

  defp nav_items do
    [
      {"general", "General"},
      {"models", "Models"},
      {"analytics", "Analytics"},
      {"apps", "Apps & Connections"},
      {"workflows", "Workflows"},
      {"skills", "Skill Permissions"},
      {"help", "Help"}
    ]
  end

  defp icon_for(section) do
    case section do
      "general" -> "hero-home"
      "models" -> "hero-cube"
      "analytics" -> "hero-chart-bar"
      "apps" -> "hero-puzzle-piece"
      "workflows" -> "hero-command-line"
      "skills" -> "hero-wrench-screwdriver"
      "help" -> "hero-question-mark-circle"
    end
  end

  defp page_title(section) do
    case section do
      "general" -> "General"
      "models" -> "Models"
      "analytics" -> "Analytics"
      "apps" -> "Apps & Connections"
      "workflows" -> "Workflows"
      "skills" -> "Skill Permissions"
      "help" -> "Help & Setup"
    end
  end

  defp filtered_help_articles(assigns) do
    query = assigns.help_query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      assigns.help_articles
    else
      Enum.filter(assigns.help_articles, fn article ->
        haystack = String.downcase("#{article.title} #{article.summary}")
        String.contains?(haystack, query)
      end)
    end
  end

  defp format_time(nil), do: "Unknown"

  defp format_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso8601
    end
  end

  defp model_to_form_data(id) do
    case ModelCatalog.get_model(id) do
      {:ok, model} ->
        %{
          "id" => model.id,
          "name" => model.name,
          "input_cost" => model.input_cost,
          "output_cost" => model.output_cost
        }

      {:error, _} ->
        %{"id" => id, "name" => id, "input_cost" => "", "output_cost" => ""}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sa-settings-shell">
        <aside class={["sa-sidebar", @sidebar_collapsed && "is-collapsed"]}>
          <div class="sa-sidebar-header">
            <div class="sa-brand-mark">A</div>
            <span :if={!@sidebar_collapsed}>Synaptic Assistant</span>
          </div>

          <nav class="sa-sidebar-nav">
            <.link
              :for={{section, label} <- nav_items()}
              navigate={if(section == "general", do: ~p"/settings", else: ~p"/settings/#{section}")}
              class={["sa-sidebar-link", section == @section && "is-active"]}
              title={label}
            >
              <.icon name={icon_for(section)} class="h-4 w-4" />
              <span :if={!@sidebar_collapsed}>{label}</span>
            </.link>
          </nav>

          <button type="button" class="sa-icon-btn" phx-click="toggle_sidebar">
            <.icon
              name={if(@sidebar_collapsed, do: "hero-chevron-double-right", else: "hero-chevron-double-left")}
              class="h-4 w-4"
            />
          </button>
        </aside>

        <section class="sa-content">
          <header class="sa-page-header">
            <h1>{page_title(@section)}</h1>
          </header>

          <div :if={@section == "general"} class="sa-card-grid">
            <article class="sa-card">
              <h2>Welcome</h2>
              <p>Configure models, workflows, app connections, permissions, and help resources.</p>
            </article>
            <article class="sa-card">
              <h2>Quick Links</h2>
              <div class="sa-chip-row">
                <.link navigate={~p"/settings/models"} class="sa-chip">Models</.link>
                <.link navigate={~p"/settings/analytics"} class="sa-chip">Analytics</.link>
                <.link navigate={~p"/settings/apps"} class="sa-chip">Apps</.link>
                <.link navigate={~p"/settings/workflows"} class="sa-chip">Workflows</.link>
                <.link navigate={~p"/settings/skills"} class="sa-chip">Skills</.link>
              </div>
            </article>
          </div>

          <div :if={@section == "models"} class="sa-card">
            <div class="sa-row">
              <h2>Active Model List</h2>
              <button class="sa-btn secondary" type="button" phx-click="open_model_modal">
                <.icon name="hero-plus" class="h-4 w-4" /> Add Model
              </button>
            </div>

            <div :if={@models == []} class="sa-empty">
              No models are currently loaded from configuration.
            </div>

            <table :if={@models != []} class="sa-table">
              <thead>
                <tr>
                  <th>Model Name</th>
                  <th>Input Cost</th>
                  <th>Output Cost</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={model <- @models}
                  class="sa-click-row"
                  phx-click="open_model_modal"
                  phx-value-id={model.id}
                >
                  <td>{model.name}</td>
                  <td>{model.input_cost}</td>
                  <td>{model.output_cost}</td>
                </tr>
              </tbody>
            </table>

            <div :if={@model_modal_open} class="sa-modal-backdrop" phx-click="close_model_modal">
              <div class="sa-modal" phx-click-away="close_model_modal">
                <div class="sa-row">
                  <h3>Model Details</h3>
                  <button type="button" class="sa-icon-btn" phx-click="close_model_modal">
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </div>

                <.form for={@model_form} id="model-form" phx-submit="save_model">
                  <.input name="model[id]" label="Model ID" value={@model_form.params["id"]} />
                  <.input name="model[name]" label="Display Name" value={@model_form.params["name"]} />
                  <.input
                    name="model[input_cost]"
                    label="Input Cost"
                    value={@model_form.params["input_cost"]}
                  />
                  <.input
                    name="model[output_cost]"
                    label="Output Cost"
                    value={@model_form.params["output_cost"]}
                  />
                  <div class="sa-row">
                    <button type="button" class="sa-btn secondary" phx-click="close_model_modal">
                      Cancel
                    </button>
                    <button type="submit" class="sa-btn">Save Model</button>
                  </div>
                </.form>
              </div>
            </div>
          </div>

          <div :if={@section == "analytics"} class="sa-card-grid">
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
                  <span>{format_time(failure.occurred_at)}</span>
                </li>
              </ul>
            </article>
          </div>

          <section :if={@section == "apps"} class="sa-card">
            <div class="sa-row">
              <h2>Connected Apps</h2>
              <button class="sa-btn" type="button" phx-click="open_add_app_modal">
                <.icon name="hero-plus" class="h-4 w-4" /> Add App
              </button>
            </div>

            <p>Only approved apps from the platform catalog can be connected.</p>

            <div class="sa-card-grid">
              <article :for={app <- @app_catalog} class="sa-card">
                <h3>{app.name}</h3>
                <p>{app.summary}</p>
                <p class="sa-muted">Scopes: {app.scopes}</p>
              </article>
            </div>

            <div :if={@apps_modal_open} class="sa-modal-backdrop" phx-click="close_add_app_modal">
              <div class="sa-modal" phx-click-away="close_add_app_modal">
                <div class="sa-row">
                  <h3>Add App</h3>
                  <button type="button" class="sa-icon-btn" phx-click="close_add_app_modal">
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </div>
                <div class="sa-card-grid">
                  <article :for={app <- @app_catalog} class="sa-card">
                    <h4>{app.name}</h4>
                    <p>{app.scopes}</p>
                    <button
                      type="button"
                      class="sa-btn secondary"
                      phx-click="add_catalog_app"
                      phx-value-id={app.id}
                    >
                      Add
                    </button>
                  </article>
                </div>
              </div>
            </div>
          </section>

          <section :if={@section == "workflows"} class="sa-card">
            <div class="sa-row">
              <h2>Workflow Cards</h2>
              <button class="sa-btn" type="button">
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
                  <button
                    type="button"
                    class={["sa-toggle", workflow.enabled && "is-on"]}
                    phx-click="toggle_workflow_enabled"
                    phx-value-name={workflow.name}
                    phx-value-enabled={to_string(!workflow.enabled)}
                  >
                    {if(workflow.enabled, do: "ON", else: "OFF")}
                  </button>
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

          <section :if={@section == "skills"} class="sa-card">
            <h2>Skill Permissions</h2>
            <p class="sa-muted">Toggle runtime permissions by Domain and Skill name.</p>

            <div :if={@skills_permissions == []} class="sa-empty">
              No registered skills were found.
            </div>

            <table :if={@skills_permissions != []} class="sa-table">
              <thead>
                <tr>
                  <th>Domain</th>
                  <th>Skill</th>
                  <th>Enabled</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={perm <- @skills_permissions}>
                  <td>{perm.domain_label}</td>
                  <td>{perm.skill_label}</td>
                  <td>
                    <button
                      type="button"
                      class={["sa-toggle", perm.enabled && "is-on"]}
                      phx-click="toggle_skill_permission"
                      phx-value-skill={perm.id}
                      phx-value-enabled={to_string(!perm.enabled)}
                    >
                      {if(perm.enabled, do: "ON", else: "OFF")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <section :if={@section == "help"} class="sa-card">
            <div :if={@help_topic == nil}>
              <div class="sa-row">
                <h2>Help Cards</h2>
              </div>
              <.form for={to_form(%{}, as: :help)} phx-change="search_help" id="help-search-form">
                <.input name="help[q]" value={@help_query} placeholder="Search help..." />
              </.form>

              <div class="sa-card-grid">
                <article :for={article <- filtered_help_articles(assigns)} class="sa-card">
                  <h3>{article.title}</h3>
                  <p>{article.summary}</p>
                  <.link navigate={~p"/settings/help?topic=#{article.slug}"} class="sa-btn secondary">
                    Open
                  </.link>
                </article>
              </div>
            </div>

            <div :if={@help_topic != nil}>
              <div class="sa-row">
                <h2>{@help_topic.title}</h2>
                <.link navigate={~p"/settings/help"} class="sa-btn secondary">Back to Help</.link>
              </div>

              <ol class="sa-help-steps">
                <li :for={step <- @help_topic.body}>{step}</li>
              </ol>
            </div>
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
