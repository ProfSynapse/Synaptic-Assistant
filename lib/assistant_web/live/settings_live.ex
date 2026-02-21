defmodule AssistantWeb.SettingsLive do
  use AssistantWeb, :live_view

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
  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.ConnectedDrives
  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Integrations.Google.Drive, as: GoogleDrive
  alias AssistantWeb.SettingsLive.Data
  alias Assistant.Workflows

  import AssistantWeb.Components.SettingsPage, only: [settings_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:sidebar_collapsed, false)
     |> assign(:section, "profile")
     |> assign(:workflows, [])
     |> assign(:models, [])
     |> assign(:profile, Data.blank_profile())
     |> assign(:profile_form, to_form(Data.blank_profile(), as: :profile))
     |> assign(:orchestrator_prompt_text, "")
     |> assign(:orchestrator_prompt_html, "")
     |> assign(:model_options, [])
     |> assign(:model_defaults, %{})
     |> assign(:model_default_roles, [])
     |> assign(:model_defaults_form, to_form(%{}, as: :defaults))
     |> assign(:model_modal_open, false)
     |> assign(:model_form, to_form(Data.blank_model_form(), as: :model))
     |> assign(:analytics_snapshot, Data.empty_analytics())
     |> assign(:transcript_filters, Data.blank_transcript_filters())
     |> assign(
       :transcript_filters_form,
       to_form(Data.blank_transcript_filters(), as: :transcripts)
     )
     |> assign(:transcript_filter_options, Data.blank_transcript_filter_options())
     |> assign(:transcripts, [])
     |> assign(:selected_transcript, nil)
     |> assign(:memory_filters, Data.blank_memory_filters())
     |> assign(:memory_filters_form, to_form(Data.blank_memory_filters(), as: :memories))
     |> assign(:memory_filter_options, Data.blank_memory_filter_options())
     |> assign(:memories, [])
     |> assign(:selected_memory, nil)
     |> assign(:apps_modal_open, false)
     |> assign(:app_catalog, Data.app_catalog())
     |> assign(:connected_drives, [])
     |> assign(:available_drives, [])
     |> assign(:drives_loading, false)
     |> assign(:google_connected, false)
     |> assign(:google_email, nil)
     |> assign(:openrouter_connected, false)
     |> assign(:skills_permissions, [])
     |> assign(:help_articles, Data.help_articles())
     |> assign(:help_topic, nil)
     |> assign(:help_query, "")
     |> load_profile()
     |> load_orchestrator_prompt()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = Data.normalize_section(Map.get(params, "section", "profile"))
    help_topic = Map.get(params, "topic")

    socket =
      socket
      |> assign(:section, section)
      |> assign(:help_topic, Data.selected_help_article(section, help_topic))
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
      Data.app_catalog()
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

  def handle_event("connect_google", _params, socket) do
    case current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      settings_user ->
        case ensure_linked_user(settings_user) do
          {:ok, user_id} ->
            case MagicLink.generate(user_id, "settings", %{}) do
              {:ok, %{token: raw_token}} ->
                {:noreply,
                 push_event(socket, "open_oauth_popup", %{
                   url: "/auth/google/start?token=#{raw_token}"
                 })}

              {:error, :rate_limited} ->
                {:noreply,
                 put_flash(socket, :error, "Too many authorization attempts. Please wait a few minutes.")}

              {:error, _reason} ->
                {:noreply,
                 put_flash(socket, :error, "Failed to start Google authorization. Please try again.")}
            end

          {:error, reason} ->
            require Logger
            Logger.error("connect_google: ensure_linked_user failed", reason: inspect(reason))

            {:noreply,
             put_flash(socket, :error,
               "Failed to prepare your account for Google authorization. Please try again."
             )}
        end
    end
  end

  def handle_event("disconnect_google", _params, socket) do
    with_linked_user(socket, fn _settings_user, user_id ->
      # Revoke token at Google before deleting from DB.
      # Failure is non-fatal — log and continue with local deletion.
      case TokenStore.get_google_token(user_id) do
        {:ok, oauth_token} ->
          case OAuth.revoke_token(oauth_token.access_token) do
            :ok -> :ok
            {:error, _reason} -> :ok
          end

        {:error, :not_connected} ->
          :ok
      end

      TokenStore.delete_google_token(user_id)

      {:noreply,
       socket
       |> assign(:google_connected, false)
       |> assign(:google_email, nil)
       |> put_flash(:info, "Google Workspace disconnected.")}
    end)
  end

  def handle_event("disconnect_openrouter", _params, socket) do
    with_settings_user(socket, fn settings_user ->
      Accounts.delete_openrouter_api_key(settings_user)

      {:noreply,
       socket
       |> assign(:openrouter_connected, false)
       |> put_flash(:info, "OpenRouter disconnected.")}
    end)
  end

  def handle_event("refresh_drives", _params, socket) do
    socket = assign(socket, :drives_loading, true)

    user_id = current_user_id(socket)

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
    with_linked_user(socket, fn _settings_user, user_id ->
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
    end)
  end

  def handle_event("connect_personal_drive", _params, socket) do
    with_linked_user(socket, fn _settings_user, user_id ->
      case ConnectedDrives.ensure_personal_drive(user_id) do
        {:ok, _drive} ->
          {:noreply,
           socket
           |> load_connected_drives()
           |> put_flash(:info, "Connected My Drive.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to connect My Drive.")}
      end
    end)
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
        id when id in [nil, ""] ->
          Data.blank_model_form()

        id ->
          model_to_form_data(id)
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
    do: socket |> load_google_status() |> load_openrouter_status() |> load_connected_drives()

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
      assign(socket, :analytics_snapshot, Data.empty_analytics())
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
      |> assign(:transcript_filter_options, Data.blank_transcript_filter_options())
      |> assign(:transcripts, [])
  end

  defp load_memories(socket) do
    filters = socket.assigns.memory_filters || %{}
    user_id = current_user_id(socket)

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
      |> assign(:memory_filter_options, Data.blank_memory_filter_options())
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

  defp load_openrouter_status(socket) do
    case current_settings_user(socket) do
      %{openrouter_api_key: key} when not is_nil(key) and key != "" ->
        assign(socket, :openrouter_connected, true)

      _ ->
        assign(socket, :openrouter_connected, false)
    end
  rescue
    _ -> socket
  end

  defp load_connected_drives(socket) do
    case current_user_id(socket) do
      nil ->
        socket

      user_id ->
        drives = ConnectedDrives.list_for_user(user_id)
        assign(socket, :connected_drives, drives)
    end
  rescue
    _ -> socket
  end

  defp load_profile(socket) do
    profile =
      case current_settings_user(socket) do
        nil ->
          Data.blank_profile()

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

  defp model_to_form_data(id) do
    case ModelCatalog.get_model(id) do
      {:ok, model} ->
        %{
          "id" => model.id,
          "name" => model.name,
          "input_cost" => model.input_cost,
          "output_cost" => model.output_cost,
          "max_context_tokens" => model.max_context_tokens
        }

      {:error, _} ->
        %{
          "id" => id,
          "name" => id,
          "input_cost" => "",
          "output_cost" => "",
          "max_context_tokens" => ""
        }
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
    do: Data.blank_transcript_filters()

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
    do: Data.blank_memory_filters()

  defp current_settings_user(socket) do
    case socket.assigns[:current_scope] do
      %Scope{settings_user: settings_user} -> settings_user
      _ -> nil
    end
  end

  defp current_user_id(socket) do
    case current_settings_user(socket) do
      %{user_id: user_id} when not is_nil(user_id) -> user_id
      _ -> nil
    end
  end

  defp with_settings_user(socket, callback) when is_function(callback, 1) do
    case current_settings_user(socket) do
      nil -> {:noreply, put_flash(socket, :error, "You must be logged in.")}
      settings_user -> callback.(settings_user)
    end
  end

  # If the settings_user already has a linked chat user, return it.
  # Otherwise auto-create a users record and bridge it, so the OAuth
  # token has somewhere to live for chat-initiated Google skills.
  defp ensure_linked_user(%{user_id: user_id}) when not is_nil(user_id), do: {:ok, user_id}

  defp ensure_linked_user(settings_user) do
    user_attrs = %{
      external_id: "settings:#{settings_user.id}",
      channel: "settings",
      display_name: settings_user.display_name
    }

    case %Assistant.Schemas.User{}
         |> Assistant.Schemas.User.changeset(user_attrs)
         |> Assistant.Repo.insert() do
      {:ok, user} ->
        settings_user
        |> Ecto.Changeset.change(user_id: user.id)
        |> Assistant.Repo.update()
        |> case do
          {:ok, _} -> {:ok, user.id}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp with_linked_user(socket, callback) when is_function(callback, 2) do
    case current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      %{user_id: user_id} = settings_user when not is_nil(user_id) ->
        callback.(settings_user, user_id)

      _settings_user ->
        {:noreply, put_flash(socket, :error, "No linked user account.")}
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
      Enum.map(messages, fn message -> "#{humanize_field(field)} #{message}" end)
    end)
    |> case do
      [message | _] -> message
      _ -> "Invalid profile values"
    end
  end

  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_page {assigns} />
    </Layouts.app>
    """
  end
end
