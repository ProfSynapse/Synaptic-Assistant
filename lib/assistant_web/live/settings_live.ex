defmodule AssistantWeb.SettingsLive do
  use AssistantWeb, :live_view

  alias Phoenix.LiveView.JS

  alias Assistant.Analytics
  alias Assistant.Accounts
  alias Assistant.Accounts.Scope
  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.MemoryExplorer
  alias Assistant.ModelCatalog
  alias Assistant.ModelDefaults
  alias Assistant.OrchestratorSystemPrompt
  alias Assistant.SkillPermissions
  alias Assistant.Transcripts
  alias Assistant.Auth.TokenStore
  alias Assistant.ConnectedDrives
  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Integrations.Google.Drive, as: GoogleDrive
  alias Assistant.Workflows

  import AssistantWeb.Components.DriveSettings, only: [drive_settings: 1]
  import AssistantWeb.Components.GoogleConnectStatus, only: [google_connect_status: 1]

  @sections ~w(profile models analytics memory apps workflows skills help)

  @app_catalog [
    %{
      id: "google_workspace",
      name: "Google Workspace",
      icon_path: "/images/apps/google.svg",
      scopes: "Gmail, Calendar, Drive",
      summary: "Connect approved Google tools for email, calendars, and docs."
    },
    %{
      id: "hubspot",
      name: "HubSpot",
      icon_path: "/images/apps/hubspot.svg",
      scopes: "Contacts, Deals",
      summary: "Sync CRM tasks and account updates from HubSpot."
    },
    %{
      id: "slack",
      name: "Slack",
      icon_path: "/images/apps/slack.svg",
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
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:sidebar_collapsed, false)
     |> assign(:section, "profile")
     |> assign(:workflows, [])
     |> assign(:models, [])
     |> assign(:profile, %{"display_name" => "", "email" => "", "timezone" => "UTC"})
     |> assign(:profile_form, to_form(%{}, as: :profile))
     |> assign(:orchestrator_prompt_text, "")
     |> assign(:orchestrator_prompt_html, "")
     |> assign(:model_options, [])
     |> assign(:model_defaults, %{})
     |> assign(:model_default_roles, [])
     |> assign(:model_defaults_form, to_form(%{}, as: :defaults))
     |> assign(:model_modal_open, false)
     |> assign(
       :model_form,
       to_form(%{"id" => "", "name" => "", "input_cost" => "", "output_cost" => ""}, as: :model)
     )
     |> assign(:analytics_snapshot, @empty_analytics)
     |> assign(:transcript_filters, %{
       "query" => "",
       "channel" => "",
       "status" => "",
       "agent_type" => ""
     })
     |> assign(:transcript_filters_form, to_form(%{}, as: :transcripts))
     |> assign(:transcript_filter_options, %{channels: [], statuses: [], agent_types: []})
     |> assign(:transcripts, [])
     |> assign(:selected_transcript, nil)
     |> assign(:memory_filters, %{
       "query" => "",
       "category" => "",
       "source_type" => "",
       "tag" => "",
       "source_conversation_id" => ""
     })
     |> assign(:memory_filters_form, to_form(%{}, as: :memories))
     |> assign(:memory_filter_options, %{categories: [], source_types: [], tags: []})
     |> assign(:memories, [])
     |> assign(:selected_memory, nil)
     |> assign(:apps_modal_open, false)
     |> assign(:app_catalog, @app_catalog)
     |> assign(:connected_drives, [])
     |> assign(:available_drives, [])
     |> assign(:drives_loading, false)
     |> assign(:google_connected, false)
     |> assign(:google_email, nil)
     |> assign(:skills_permissions, [])
     |> assign(:help_articles, @help_articles)
     |> assign(:help_topic, nil)
     |> assign(:help_query, "")
     |> load_profile()
     |> load_orchestrator_prompt()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = normalize_section(Map.get(params, "section", "profile"))
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

  def handle_event("new_workflow", _params, socket) do
    case Workflows.create_workflow() do
      {:ok, workflow} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created workflow: #{workflow.name}")
         |> push_navigate(to: ~p"/settings/workflows/#{workflow.name}/edit")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create workflow: #{inspect(reason)}")}
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

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:model_modal_open, false)
     |> assign(:apps_modal_open, false)}
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

  def handle_event("disconnect_google", _params, socket) do
    case current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      %{user_id: user_id} when not is_nil(user_id) ->
        TokenStore.delete_google_token(user_id)

        {:noreply,
         socket
         |> assign(:google_connected, false)
         |> assign(:google_email, nil)
         |> put_flash(:info, "Google Workspace disconnected.")}

      _settings_user ->
        {:noreply, put_flash(socket, :error, "No linked user account.")}
    end
  end

  def handle_event("refresh_drives", _params, socket) do
    socket = assign(socket, :drives_loading, true)

    user_id =
      case current_settings_user(socket) do
        %{user_id: uid} when not is_nil(uid) -> uid
        _ -> nil
      end

    token_result =
      if user_id,
        do: GoogleAuth.user_token(user_id),
        else: {:error, :no_user}

    case token_result do
      {:ok, access_token} ->
        case GoogleDrive.list_shared_drives(access_token) do
          {:ok, drives} ->
            {:noreply,
             socket
             |> assign(:available_drives, drives)
             |> assign(:drives_loading, false)
             |> put_flash(:info, "Discovered #{length(drives)} shared drive(s).")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:drives_loading, false)
             |> put_flash(:error, "Failed to fetch shared drives from Google.")}
        end

      {:error, :not_connected} ->
        {:noreply,
         socket
         |> assign(:drives_loading, false)
         |> put_flash(:error, "Connect your Google account first to discover drives.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:drives_loading, false)
         |> put_flash(:error, "Google credentials not configured.")}
    end
  end

  def handle_event("toggle_drive", %{"id" => id, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case ConnectedDrives.toggle(id, enabled?) do
      {:ok, _drive} ->
        {:noreply, load_connected_drives(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Drive not found.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle drive.")}
    end
  end

  def handle_event("connect_drive", %{"drive_id" => drive_id, "name" => name}, socket) do
    case current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      %{user_id: user_id} when not is_nil(user_id) ->
        attrs = %{drive_id: drive_id, drive_name: name, drive_type: "shared"}

        case ConnectedDrives.connect(user_id, attrs) do
          {:ok, _drive} ->
            {:noreply,
             socket
             |> load_connected_drives()
             |> put_flash(:info, "Connected #{name}.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to connect #{name}.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No linked user account.")}
    end
  end

  def handle_event("connect_personal_drive", _params, socket) do
    case current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      %{user_id: user_id} when not is_nil(user_id) ->
        case ConnectedDrives.ensure_personal_drive(user_id) do
          {:ok, _drive} ->
            {:noreply,
             socket
             |> load_connected_drives()
             |> put_flash(:info, "Connected My Drive.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to connect My Drive.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No linked user account.")}
    end
  end

  def handle_event("disconnect_drive", %{"id" => id}, socket) do
    case ConnectedDrives.disconnect(id) do
      {:ok, _drive} ->
        {:noreply,
         socket
         |> load_connected_drives()
         |> put_flash(:info, "Drive disconnected.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to disconnect drive.")}
    end
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

  def handle_event("save_model_defaults", %{"defaults" => params}, socket) do
    case ModelDefaults.save_defaults(params) do
      :ok ->
        {:noreply,
         socket
         |> load_models()
         |> put_flash(:info, "Default models updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save defaults: #{inspect(reason)}")}
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

  def handle_event("save_profile", %{"profile" => params}, socket) do
    save_profile(socket, params, flash?: true)
  end

  def handle_event("autosave_profile", %{"profile" => params}, socket) do
    save_profile(socket, params, flash?: false)
  end

  def handle_event("autosave_orchestrator_prompt", %{"body" => body}, socket) do
    content = body |> to_string()
    socket = notify_autosave(socket, "saving", "Saving system instructions...")

    case OrchestratorSystemPrompt.save_prompt(content) do
      :ok ->
        {:noreply,
         socket
         |> assign(:orchestrator_prompt_text, content)
         |> assign(:orchestrator_prompt_html, markdown_to_html(content))
         |> notify_autosave("saved", "All changes saved")}

      {:error, reason} ->
        {:noreply,
         socket
         |> notify_autosave("error", "Could not save system instructions")
         |> put_flash(:error, "Failed to save prompt: #{inspect(reason)}")}
    end
  end

  def handle_event("filter_transcripts", %{"transcripts" => params}, socket) do
    filters = normalize_transcript_filters(params)

    {:noreply,
     socket
     |> assign(:transcript_filters, filters)
     |> assign(:transcript_filters_form, to_form(filters, as: :transcripts))
     |> assign(:selected_transcript, nil)
     |> load_transcripts()}
  end

  def handle_event("view_transcript", %{"id" => id}, socket) do
    case Transcripts.get_transcript(id) do
      {:ok, transcript} ->
        {:noreply, assign(socket, :selected_transcript, transcript)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Transcript not found")}
    end
  end

  def handle_event("close_transcript", _params, socket) do
    {:noreply, assign(socket, :selected_transcript, nil)}
  end

  def handle_event("filter_memories", %{"memories" => params}, socket) do
    filters = normalize_memory_filters(params)

    {:noreply,
     socket
     |> assign(:memory_filters, filters)
     |> assign(:memory_filters_form, to_form(filters, as: :memories))
     |> assign(:selected_memory, nil)
     |> load_memories()}
  end

  def handle_event("view_memory", %{"id" => id}, socket) do
    case MemoryExplorer.get_memory(id) do
      {:ok, memory} ->
        {:noreply, assign(socket, :selected_memory, memory)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Memory not found")}
    end
  end

  def handle_event("close_memory", _params, socket) do
    {:noreply, assign(socket, :selected_memory, nil)}
  end

  defp load_section_data(socket, "profile"),
    do: socket |> load_profile() |> load_orchestrator_prompt()

  defp load_section_data(socket, "workflows"), do: reload_workflows(socket)
  defp load_section_data(socket, "models"), do: load_models(socket)
  defp load_section_data(socket, "analytics"), do: load_analytics(socket)
  defp load_section_data(socket, "memory"), do: socket |> load_transcripts() |> load_memories()
  defp load_section_data(socket, "apps"),
    do: socket |> load_google_status() |> load_connected_drives()
  defp load_section_data(socket, "skills"), do: load_skill_permissions(socket)
  defp load_section_data(socket, _section), do: socket

  defp reload_workflows(socket) do
    case Workflows.list_workflows() do
      {:ok, workflows} -> assign(socket, :workflows, workflows)
      {:error, _reason} -> assign(socket, :workflows, [])
    end
  end

  defp load_models(socket) do
    models = ModelCatalog.list_models()
    roles = model_roles()
    explicit_defaults = ModelDefaults.list_defaults()

    current_defaults =
      Enum.reduce(roles, %{}, fn role, acc ->
        key = Atom.to_string(role)
        value = Map.get(explicit_defaults, key) || resolved_default_model_id(role)
        Map.put(acc, key, value || "")
      end)

    options = Enum.map(models, fn model -> {model.name, model.id} end)

    socket
    |> assign(:models, models)
    |> assign(:model_options, options)
    |> assign(:model_defaults, current_defaults)
    |> assign(:model_default_roles, Enum.map(roles, &Atom.to_string/1))
    |> assign(:model_defaults_form, to_form(current_defaults, as: :defaults))
  end

  defp load_analytics(socket) do
    snapshot = Analytics.dashboard_snapshot(window_days: 7)
    assign(socket, :analytics_snapshot, snapshot)
  rescue
    _ ->
      assign(socket, :analytics_snapshot, @empty_analytics)
  end

  defp load_transcripts(socket) do
    filters = socket.assigns.transcript_filters || %{}

    query_opts = [
      query: Map.get(filters, "query", ""),
      channel: Map.get(filters, "channel", ""),
      status: Map.get(filters, "status", ""),
      agent_type: Map.get(filters, "agent_type", ""),
      limit: 60
    ]

    options = Transcripts.filter_options()
    transcripts = Transcripts.list_transcripts(query_opts)

    socket
    |> assign(:transcript_filter_options, options)
    |> assign(:transcripts, transcripts)
    |> assign(:transcript_filters_form, to_form(filters, as: :transcripts))
  rescue
    _ ->
      socket
      |> assign(:transcript_filter_options, %{channels: [], statuses: [], agent_types: []})
      |> assign(:transcripts, [])
  end

  defp load_memories(socket) do
    filters = socket.assigns.memory_filters || %{}

    user_id =
      case current_settings_user(socket) do
        %{user_id: uid} when not is_nil(uid) -> uid
        _ -> nil
      end

    query_opts = [
      user_id: user_id,
      query: Map.get(filters, "query", ""),
      category: Map.get(filters, "category", ""),
      source_type: Map.get(filters, "source_type", ""),
      tag: Map.get(filters, "tag", ""),
      source_conversation_id: Map.get(filters, "source_conversation_id", ""),
      limit: 80
    ]

    options = MemoryExplorer.filter_options(user_id: user_id)
    memories = MemoryExplorer.list_memories(query_opts)

    socket
    |> assign(:memory_filter_options, options)
    |> assign(:memories, memories)
    |> assign(:memory_filters_form, to_form(filters, as: :memories))
  rescue
    _ ->
      socket
      |> assign(:memory_filter_options, %{categories: [], source_types: [], tags: []})
      |> assign(:memories, [])
  end

  defp load_skill_permissions(socket) do
    assign(socket, :skills_permissions, SkillPermissions.list_permissions())
  end

  defp load_google_status(socket) do
    case current_settings_user(socket) do
      %{user_id: user_id} when not is_nil(user_id) ->
        case TokenStore.get_google_token(user_id) do
          {:ok, token} ->
            socket
            |> assign(:google_connected, true)
            |> assign(:google_email, token.provider_email)

          {:error, :not_connected} ->
            socket
            |> assign(:google_connected, false)
            |> assign(:google_email, nil)
        end

      _ ->
        socket
    end
  rescue
    _ -> socket
  end

  defp load_connected_drives(socket) do
    case current_settings_user(socket) do
      %{user_id: user_id} when not is_nil(user_id) ->
        drives = ConnectedDrives.list_for_user(user_id)
        assign(socket, :connected_drives, drives)

      _ ->
        socket
    end
  rescue
    _ -> socket
  end

  defp load_profile(socket) do
    profile =
      case current_settings_user(socket) do
        nil ->
          %{"display_name" => "", "email" => "", "timezone" => "UTC"}

        settings_user ->
          %{
            "display_name" => settings_user.display_name || "",
            "email" => settings_user.email || "",
            "timezone" => settings_user.timezone || "UTC"
          }
      end

    socket
    |> assign(:profile, profile)
    |> assign(:profile_form, to_form(profile, as: :profile))
  end

  defp load_orchestrator_prompt(socket) do
    prompt = OrchestratorSystemPrompt.get_prompt()

    socket
    |> assign(:orchestrator_prompt_text, prompt)
    |> assign(:orchestrator_prompt_html, markdown_to_html(prompt))
  end

  defp markdown_to_html(markdown) when is_binary(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _messages} -> html
      _ -> ""
    end
  end

  defp markdown_to_html(_), do: ""

  defp normalize_section(section) when section in @sections, do: section
  defp normalize_section("general"), do: "profile"
  defp normalize_section("transcripts"), do: "memory"
  defp normalize_section(_), do: "profile"

  defp selected_help_article("help", nil), do: nil

  defp selected_help_article("help", slug) do
    Enum.find(@help_articles, &(&1.slug == slug))
  end

  defp selected_help_article(_, _), do: nil

  defp nav_items do
    [
      {"profile", "Profile"},
      {"models", "Models"},
      {"analytics", "Analytics"},
      {"memory", "Memory"},
      {"apps", "Apps & Connections"},
      {"workflows", "Workflows"},
      {"skills", "Skill Permissions"},
      {"help", "Help"}
    ]
  end

  defp icon_for(section) do
    case section do
      "profile" -> "hero-user-circle"
      "models" -> "hero-cube"
      "analytics" -> "hero-chart-bar"
      "memory" -> "hero-document-text"
      "apps" -> "hero-puzzle-piece"
      "workflows" -> "hero-command-line"
      "skills" -> "hero-wrench-screwdriver"
      "help" -> "hero-question-mark-circle"
    end
  end

  defp page_title(section) do
    case section do
      "profile" -> "Profile"
      "models" -> "Models"
      "analytics" -> "Analytics"
      "memory" -> "Memory"
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

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

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

  defp normalize_transcript_filters(params) when is_map(params) do
    %{
      "query" => Map.get(params, "query", "") |> to_string() |> String.trim(),
      "channel" => Map.get(params, "channel", "") |> to_string() |> String.trim(),
      "status" => Map.get(params, "status", "") |> to_string() |> String.trim(),
      "agent_type" => Map.get(params, "agent_type", "") |> to_string() |> String.trim()
    }
  end

  defp normalize_transcript_filters(_),
    do: %{"query" => "", "channel" => "", "status" => "", "agent_type" => ""}

  defp normalize_memory_filters(params) when is_map(params) do
    %{
      "query" => Map.get(params, "query", "") |> to_string() |> String.trim(),
      "category" => Map.get(params, "category", "") |> to_string() |> String.trim(),
      "source_type" => Map.get(params, "source_type", "") |> to_string() |> String.trim(),
      "tag" => Map.get(params, "tag", "") |> to_string() |> String.trim(),
      "source_conversation_id" =>
        Map.get(params, "source_conversation_id", "") |> to_string() |> String.trim()
    }
  end

  defp normalize_memory_filters(_),
    do: %{
      "query" => "",
      "category" => "",
      "source_type" => "",
      "tag" => "",
      "source_conversation_id" => ""
    }

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "unknown"

  defp display_message_content(message) do
    content = Map.get(message, :content) || Map.get(message, "content")
    tool_calls = Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    tool_results = Map.get(message, :tool_results) || Map.get(message, "tool_results")

    cond do
      is_binary(content) and String.trim(content) != "" ->
        content

      is_map(tool_calls) ->
        "Tool calls: " <> Jason.encode!(tool_calls)

      is_map(tool_results) ->
        "Tool results: " <> Jason.encode!(tool_results)

      true ->
        "(no content)"
    end
  end

  defp format_importance(%Decimal{} = value), do: value |> Decimal.to_float() |> Float.round(2)
  defp format_importance(value) when is_float(value), do: Float.round(value, 2)
  defp format_importance(value) when is_integer(value), do: value
  defp format_importance(_), do: "-"

  defp format_tags(tags) when is_list(tags) do
    tags
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "-"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_tags(_), do: "-"

  defp humanize(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        "-"

      trimmed ->
        trimmed
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()
  defp humanize(nil), do: "-"
  defp humanize(value), do: to_string(value) |> humanize()

  defp profile_first_name(profile) when is_map(profile) do
    profile
    |> Map.get("display_name", "")
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        "there"

      full_name ->
        full_name
        |> String.split()
        |> List.first()
    end
  end

  defp profile_first_name(_), do: "there"

  defp current_settings_user(socket) do
    case socket.assigns[:current_scope] do
      %Scope{settings_user: settings_user} -> settings_user
      _ -> nil
    end
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{humanize(field)} #{message}" end)
    end)
    |> case do
      [message | _] -> message
      _ -> "Invalid profile values"
    end
  end

  defp save_profile(socket, params, opts) do
    flash? = Keyword.get(opts, :flash?, false)
    merged_profile = merge_profile_params(socket.assigns.profile, params)

    socket =
      socket
      |> assign(:profile, merged_profile)
      |> assign(:profile_form, to_form(merged_profile, as: :profile))
      |> notify_autosave("saving", "Saving profile...")

    case current_settings_user(socket) do
      nil ->
        socket =
          socket
          |> notify_autosave("error", "Could not save profile")
          |> maybe_put_profile_flash(
            flash?,
            :error,
            "You must be logged in to update profile settings"
          )

        {:noreply, socket}

      settings_user ->
        case Accounts.update_settings_user_profile(settings_user, merged_profile) do
          {:ok, updated_user} ->
            socket =
              socket
              |> assign(:current_scope, Scope.for_settings_user(updated_user))
              |> load_profile()
              |> notify_autosave("saved", "All changes saved")
              |> maybe_put_profile_flash(flash?, :info, "Profile updated")

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            message = format_changeset_errors(changeset)

            socket =
              socket
              |> notify_autosave("error", "Could not save profile")
              |> maybe_put_profile_flash(flash?, :error, "Failed to save profile: #{message}")

            {:noreply, socket}

          {:error, reason} ->
            message = inspect(reason)

            socket =
              socket
              |> notify_autosave("error", "Could not save profile")
              |> maybe_put_profile_flash(flash?, :error, "Failed to save profile: #{message}")

            {:noreply, socket}
        end
    end
  end

  defp maybe_put_profile_flash(socket, true, kind, message), do: put_flash(socket, kind, message)
  defp maybe_put_profile_flash(socket, false, _kind, _message), do: socket

  defp notify_autosave(socket, state, message) do
    push_event(socket, "autosave:status", %{state: state, message: message})
  end

  defp merge_profile_params(existing_profile, params) do
    %{
      "display_name" =>
        Map.get(params, "display_name", Map.get(existing_profile, "display_name", "")),
      "email" => Map.get(params, "email", Map.get(existing_profile, "email", "")),
      "timezone" => Map.get(params, "timezone", Map.get(existing_profile, "timezone", "UTC"))
    }
  end

  defp model_roles do
    try do
      ConfigLoader.defaults()
      |> Map.keys()
      |> Enum.sort()
    rescue
      _ ->
        [:orchestrator, :sub_agent, :compaction, :sentinel]
    end
  end

  defp resolved_default_model_id(role) do
    try do
      case ConfigLoader.model_for(role) do
        nil -> nil
        model -> model.id
      end
    rescue
      _ -> nil
    end
  end

  defp role_label(role_key) do
    role_key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sa-settings-shell">
        <aside class={["sa-sidebar", @sidebar_collapsed && "is-collapsed"]}>
          <div class="sa-sidebar-header">
            <div class="sa-sidebar-brand">
              <div class="sa-brand-mark">A</div>
              <span :if={!@sidebar_collapsed}>Synaptic Assistant</span>
            </div>
            <button type="button" class="sa-icon-btn sa-sidebar-toggle" phx-click="toggle_sidebar" aria-label="Toggle sidebar">
              <.icon name="hero-bars-3" class="h-4 w-4" />
            </button>
          </div>

          <nav class="sa-sidebar-nav">
            <.link
              :for={{section, label} <- nav_items()}
              navigate={if(section == "profile", do: ~p"/settings", else: ~p"/settings/#{section}")}
              class={["sa-sidebar-link", section == @section && "is-active"]}
              title={label}
            >
              <.icon name={icon_for(section)} class="h-4 w-4" />
              <span :if={!@sidebar_collapsed}>{label}</span>
            </.link>
          </nav>

          <div class="sa-sidebar-footer">
            <.link href={~p"/settings_users/log-out"} method="delete" class="sa-sidebar-link" title="Log Out">
              <.icon name="hero-arrow-right-on-rectangle" class="h-4 w-4" />
              <span :if={!@sidebar_collapsed}>Log Out</span>
            </.link>
          </div>
        </aside>

        <section class="sa-content">
          <header class="sa-page-header">
            <h1>{page_title(@section)}</h1>
            <p :if={@section == "profile"} class="sa-page-subtitle">
              Welcome back, {profile_first_name(@profile)}.
            </p>
          </header>

          <section :if={@section == "profile"} class="sa-section-stack">
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

          <div :if={@section == "models"} class="sa-card">
            <h2>Role Defaults</h2>
            <p class="sa-muted">Choose the default model used for each system role.</p>

            <.form
              for={@model_defaults_form}
              id="model-defaults-form"
              phx-submit="save_model_defaults"
              class="sa-model-defaults-form"
            >
              <div class="sa-model-defaults-grid">
                <.input
                  :for={role <- @model_default_roles}
                  type="select"
                  name={"defaults[#{role}]"}
                  label={role_label(role)}
                  options={@model_options}
                  value={Map.get(@model_defaults, role)}
                  prompt="Select model"
                />
              </div>
              <div class="sa-model-defaults-actions">
                <button type="submit" class="sa-btn">Save Defaults</button>
              </div>
            </.form>
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

            <.modal :if={@model_modal_open} id="model-modal" title="Model Details" max_width="md" on_cancel={JS.push("close_model_modal")}>
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
            </.modal>
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

          <section :if={@section == "memory"} class="sa-section-stack">
            <article class="sa-card">
              <h2>Transcripts</h2>
              <p class="sa-muted">Search, filter, and read conversation transcripts and related tasks.</p>

              <.form
                for={@transcript_filters_form}
                as={:transcripts}
                id="transcript-filters-form"
                phx-change="filter_transcripts"
                class="sa-transcript-filters"
              >
                <.input
                  name="transcripts[query]"
                  label="Search"
                  value={@transcript_filters["query"]}
                  placeholder="Conversation ID or message text"
                  phx-debounce="300"
                />
                <.input
                  type="select"
                  name="transcripts[channel]"
                  label="Channel"
                  value={@transcript_filters["channel"]}
                  options={Enum.map(@transcript_filter_options.channels, &{&1, &1})}
                  prompt="All channels"
                />
                <.input
                  type="select"
                  name="transcripts[status]"
                  label="Status"
                  value={@transcript_filters["status"]}
                  options={Enum.map(@transcript_filter_options.statuses, &{String.capitalize(&1), &1})}
                  prompt="All statuses"
                />
                <.input
                  type="select"
                  name="transcripts[agent_type]"
                  label="Agent Type"
                  value={@transcript_filters["agent_type"]}
                  options={
                    Enum.map(@transcript_filter_options.agent_types, fn v ->
                      {humanize(v), v}
                    end)
                  }
                  prompt="All agent types"
                />
              </.form>

              <div :if={@transcripts == []} class="sa-empty">
                No transcripts found for current filters.
              </div>

              <table :if={@transcripts != []} class="sa-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Channel</th>
                    <th>Agent</th>
                    <th>Status</th>
                    <th>Messages</th>
                    <th>Last Active</th>
                    <th>Preview</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={transcript <- @transcripts}
                    class="sa-click-row"
                    phx-click="view_transcript"
                    phx-value-id={transcript.id}
                  >
                    <td>{short_id(transcript.id)}</td>
                    <td>{transcript.channel || "-"}</td>
                    <td>{humanize(transcript.agent_type)}</td>
                    <td>{humanize(transcript.status)}</td>
                    <td>{transcript.message_count || 0}</td>
                    <td>{format_time(transcript.last_active_at || transcript.inserted_at)}</td>
                    <td>{transcript.preview}</td>
                  </tr>
                </tbody>
              </table>

              <section :if={not is_nil(@selected_transcript)} class="sa-subcard">
                <div class="sa-row">
                  <h3>Transcript {short_id(@selected_transcript.conversation.id)}</h3>
                  <button type="button" class="sa-btn secondary" phx-click="close_transcript">
                    Close
                  </button>
                </div>

                <div class="sa-chip-row">
                  <span class="sa-chip">Channel: {@selected_transcript.conversation.channel}</span>
                  <span class="sa-chip">Status: {humanize(@selected_transcript.conversation.status)}</span>
                  <span class="sa-chip">Agent: {humanize(@selected_transcript.conversation.agent_type)}</span>
                  <span class="sa-chip">
                    Started: {format_time(
                      @selected_transcript.conversation.started_at || @selected_transcript.conversation.inserted_at
                    )}
                  </span>
                </div>

                <div :if={@selected_transcript.related_tasks != []} class="sa-subcard">
                  <h4>Related Tasks</h4>
                  <table class="sa-table">
                    <thead>
                      <tr>
                        <th>Task</th>
                        <th>Title</th>
                        <th>Status</th>
                        <th>Priority</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={task <- @selected_transcript.related_tasks}>
                        <td>{task.short_id || short_id(task.id)}</td>
                        <td>{task.title}</td>
                        <td>{humanize(task.status)}</td>
                        <td>{humanize(task.priority)}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="sa-transcript-messages">
                  <article :for={message <- @selected_transcript.messages} class="sa-transcript-message">
                    <header class="sa-row">
                      <strong>{String.upcase(message.role || "unknown")}</strong>
                      <span class="sa-muted">{format_time(message.inserted_at)}</span>
                    </header>
                    <pre class="sa-transcript-content">{display_message_content(message)}</pre>
                  </article>
                </div>
              </section>
            </article>

            <article class="sa-card">
              <h2>Memory Entries</h2>
              <p class="sa-muted">Browse memories captured for long-term retrieval.</p>

              <.form
                for={@memory_filters_form}
                as={:memories}
                id="memory-filters-form"
                phx-change="filter_memories"
                class="sa-transcript-filters"
              >
                <.input
                  name="memories[query]"
                  label="Search"
                  value={@memory_filters["query"]}
                  placeholder="Memory text"
                  phx-debounce="300"
                />
                <.input
                  type="select"
                  name="memories[category]"
                  label="Category"
                  value={@memory_filters["category"]}
                  options={Enum.map(@memory_filter_options.categories, &{humanize(&1), &1})}
                  prompt="All categories"
                />
                <.input
                  type="select"
                  name="memories[source_type]"
                  label="Source Type"
                  value={@memory_filters["source_type"]}
                  options={Enum.map(@memory_filter_options.source_types, &{humanize(&1), &1})}
                  prompt="All source types"
                />
                <.input
                  type="select"
                  name="memories[tag]"
                  label="Tag"
                  value={@memory_filters["tag"]}
                  options={Enum.map(@memory_filter_options.tags, &{&1, &1})}
                  prompt="All tags"
                />
                <.input
                  name="memories[source_conversation_id]"
                  label="Source Conversation ID"
                  value={@memory_filters["source_conversation_id"]}
                  placeholder="Conversation UUID"
                  phx-debounce="300"
                />
              </.form>

              <div :if={@memories == []} class="sa-empty">
                No memory entries found for current filters.
              </div>

              <table :if={@memories != []} class="sa-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Category</th>
                    <th>Source</th>
                    <th>Tags</th>
                    <th>Importance</th>
                    <th>Created</th>
                    <th>Last Accessed</th>
                    <th>Source Conversation</th>
                    <th>Preview</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={memory <- @memories} class="sa-click-row" phx-click="view_memory" phx-value-id={memory.id}>
                    <td>{short_id(memory.id)}</td>
                    <td>{humanize(memory.category)}</td>
                    <td>{humanize(memory.source_type)}</td>
                    <td>{format_tags(memory.tags)}</td>
                    <td>{format_importance(memory.importance)}</td>
                    <td>{format_time(memory.inserted_at)}</td>
                    <td>{format_time(memory.accessed_at)}</td>
                    <td>{if(memory.source_conversation_id, do: short_id(memory.source_conversation_id), else: "-")}</td>
                    <td>{memory.preview}</td>
                  </tr>
                </tbody>
              </table>

              <section :if={not is_nil(@selected_memory)} class="sa-subcard">
                <div class="sa-row">
                  <h3>Memory {short_id(@selected_memory.id)}</h3>
                  <button type="button" class="sa-btn secondary" phx-click="close_memory">
                    Close
                  </button>
                </div>

                <div class="sa-chip-row">
                  <span class="sa-chip">Category: {humanize(@selected_memory.category)}</span>
                  <span class="sa-chip">Source: {humanize(@selected_memory.source_type)}</span>
                  <span class="sa-chip">Importance: {format_importance(@selected_memory.importance)}</span>
                  <span class="sa-chip">Created: {format_time(@selected_memory.inserted_at)}</span>
                  <span class="sa-chip">Last Accessed: {format_time(@selected_memory.accessed_at)}</span>
                  <span :if={@selected_memory.source_conversation_id} class="sa-chip">
                    Source Conversation: {short_id(@selected_memory.source_conversation_id)}
                  </span>
                  <span :if={@selected_memory.embedding_model} class="sa-chip">
                    Embedding Model: {@selected_memory.embedding_model}
                  </span>
                  <span :if={not is_nil(@selected_memory.decay_factor)} class="sa-chip">
                    Decay Factor: {format_importance(@selected_memory.decay_factor)}
                  </span>
                  <span :if={@selected_memory.segment_start_message_id} class="sa-chip">
                    Segment Start: {short_id(@selected_memory.segment_start_message_id)}
                  </span>
                  <span :if={@selected_memory.segment_end_message_id} class="sa-chip">
                    Segment End: {short_id(@selected_memory.segment_end_message_id)}
                  </span>
                </div>

                <div :if={@selected_memory.tags != []} class="sa-chip-row">
                  <span :for={tag <- @selected_memory.tags} class="sa-chip">{tag}</span>
                </div>

                <pre class="sa-transcript-content">{@selected_memory.content}</pre>
              </section>
            </article>
          </section>

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
                <div class="sa-app-title">
                  <img src={app.icon_path} alt={app.name} class="sa-app-icon" />
                  <h3>{app.name}</h3>
                </div>
                <p>{app.summary}</p>
                <p class="sa-muted">Scopes: {app.scopes}</p>
                <.google_connect_status
                  :if={app.id == "google_workspace"}
                  connected={@google_connected}
                  email={@google_email}
                />
              </article>
            </div>

            <.drive_settings
              :if={@google_connected}
              connected_drives={@connected_drives}
              available_drives={@available_drives}
              drives_loading={@drives_loading}
              has_google_token={GoogleAuth.configured?()}
            />
            <div :if={!@google_connected} class="sa-drive-settings">
              <h3>Google Drive Access</h3>
              <div class="sa-drive-notice sa-drive-notice--info">
                <.icon name="hero-information-circle" class="h-5 w-5" />
                <span>Connect your Google account above to manage Drive access.</span>
              </div>
            </div>

            <.modal :if={@apps_modal_open} id="apps-modal" title="Add App" max_width="lg" on_cancel={JS.push("close_add_app_modal")}>
              <div class="sa-card-grid">
                <article :for={app <- @app_catalog} class="sa-card">
                  <div class="sa-app-title">
                    <img src={app.icon_path} alt={app.name} class="sa-app-icon" />
                    <h4>{app.name}</h4>
                  </div>
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
            </.modal>
          </section>

          <section :if={@section == "workflows"} class="sa-card">
            <div class="sa-row">
              <h2>Workflow Cards</h2>
              <button class="sa-btn" type="button" phx-click="new_workflow">
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
                  <label class="sa-switch">
                    <input
                      type="checkbox"
                      checked={workflow.enabled}
                      class="sa-switch-input"
                      role="switch"
                      aria-checked={to_string(workflow.enabled)}
                      aria-label={"Toggle #{workflow.name}"}
                      phx-click="toggle_workflow_enabled"
                      phx-value-name={workflow.name}
                      phx-value-enabled={to_string(!workflow.enabled)}
                    />
                    <span class="sa-switch-slider"></span>
                  </label>
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
                    <label class="sa-switch">
                      <input
                        type="checkbox"
                        checked={perm.enabled}
                        class="sa-switch-input"
                        role="switch"
                        aria-checked={to_string(perm.enabled)}
                        aria-label={"Toggle #{perm.skill_label}"}
                        phx-click="toggle_skill_permission"
                        phx-value-skill={perm.id}
                        phx-value-enabled={to_string(!perm.enabled)}
                      />
                      <span class="sa-switch-slider"></span>
                    </label>
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
