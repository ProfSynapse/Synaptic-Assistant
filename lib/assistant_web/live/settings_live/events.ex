defmodule AssistantWeb.SettingsLive.Events do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, push_navigate: 2, redirect: 2]

  alias Assistant.Accounts
  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.ConnectedDrives
  alias Assistant.Integrations.OpenAI
  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Integrations.Google.Drive, as: GoogleDrive
  alias Assistant.Integrations.OpenRouter
  alias Assistant.MemoryExplorer
  alias Assistant.MemoryGraph
  alias Assistant.ModelCatalog
  alias Assistant.ModelDefaults
  alias Assistant.OrchestratorSystemPrompt
  alias Assistant.SkillPermissions
  alias Assistant.Transcripts
  alias Assistant.Workflows
  alias AssistantWeb.SettingsLive.Context
  alias AssistantWeb.SettingsLive.Data
  alias AssistantWeb.SettingsLive.Loaders
  alias AssistantWeb.SettingsLive.Profile

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_workflow_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case Workflows.set_enabled(name, enabled?) do
      {:ok, _workflow} ->
        {:noreply, Loaders.reload_workflows(socket)}

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
         |> push_navigate(to: "/settings/workflows/#{workflow.name}/edit")}

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
         |> Loaders.reload_workflows()}

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
    case Context.current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      settings_user ->
        case Context.ensure_linked_user(settings_user) do
          {:ok, user_id} ->
            case MagicLink.generate(user_id, "settings", %{}) do
              {:ok, %{token: raw_token}} ->
                {:noreply,
                 push_event(socket, "open_oauth_popup", %{
                   url: "/auth/google/start?token=#{raw_token}"
                 })}

              {:error, :rate_limited} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Too many authorization attempts. Please wait a few minutes."
                 )}

              {:error, _reason} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Failed to start Google authorization. Please try again."
                 )}
            end

          {:error, reason} ->
            require Logger
            Logger.error("connect_google: ensure_linked_user failed", reason: inspect(reason))

            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to prepare your account for Google authorization. Please try again."
             )}
        end
    end
  end

  def handle_event("disconnect_google", _params, socket) do
    Context.with_linked_user(socket, fn _settings_user, user_id ->
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
    Context.with_settings_user(socket, fn settings_user ->
      Accounts.delete_openrouter_api_key(settings_user)

      {:noreply,
       socket
       |> assign(:openrouter_connected, false)
       |> assign(:openrouter_key_form_open, false)
       |> assign(:openrouter_key_form, api_key_form(:openrouter_key))
       |> put_flash(:info, "OpenRouter disconnected.")}
    end)
  end

  def handle_event("connect_openrouter", _params, socket) do
    {:noreply, redirect(socket, to: "/settings_users/auth/openrouter")}
  end

  def handle_event("toggle_openrouter_key_form", _params, socket) do
    {:noreply,
     assign(socket, :openrouter_key_form_open, !socket.assigns.openrouter_key_form_open)}
  end

  def handle_event(
        "save_openrouter_api_key",
        %{"openrouter_key" => %{"api_key" => api_key}},
        socket
      ) do
    normalized_key = api_key |> to_string() |> String.trim()

    cond do
      normalized_key == "" ->
        {:noreply, put_flash(socket, :error, "Enter an OpenRouter API key.")}

      true ->
        Context.with_settings_user(socket, fn settings_user ->
          case OpenRouter.validate_api_key(normalized_key) do
            :ok ->
              case Accounts.save_openrouter_api_key(settings_user, normalized_key) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> assign(:openrouter_connected, true)
                   |> assign(:openrouter_key_form_open, false)
                   |> assign(:openrouter_key_form, api_key_form(:openrouter_key))
                   |> put_flash(:info, "OpenRouter connected and validated.")}

                {:error, _changeset} ->
                  {:noreply, put_flash(socket, :error, "Failed to save your OpenRouter key.")}
              end

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "OpenRouter key validation failed.")}
          end
        end)
    end
  end

  def handle_event("connect_openai", _params, socket) do
    {:noreply,
     push_event(socket, "open_oauth_popup", %{
       url: "/settings_users/auth/openai?popup=1&flow=device",
       name: "openai_oauth"
     })}
  end

  def handle_event("disconnect_openai", _params, socket) do
    Context.with_settings_user(socket, fn settings_user ->
      Accounts.delete_openai_api_key(settings_user)

      {:noreply,
       socket
       |> assign(:openai_connected, false)
       |> assign(:openai_key_form_open, false)
       |> assign(:openai_key_form, api_key_form(:openai_key))
       |> put_flash(:info, "OpenAI disconnected.")}
    end)
  end

  def handle_event("toggle_openai_key_form", _params, socket) do
    {:noreply, assign(socket, :openai_key_form_open, !socket.assigns.openai_key_form_open)}
  end

  def handle_event("save_openai_api_key", %{"openai_key" => %{"api_key" => api_key}}, socket) do
    normalized_key = api_key |> to_string() |> String.trim()

    cond do
      normalized_key == "" ->
        {:noreply, put_flash(socket, :error, "Enter an OpenAI API key.")}

      true ->
        Context.with_settings_user(socket, fn settings_user ->
          case OpenAI.validate_api_key(normalized_key) do
            :ok ->
              case Accounts.save_openai_api_key(settings_user, normalized_key) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> assign(:openai_connected, true)
                   |> assign(:openai_key_form_open, false)
                   |> assign(:openai_key_form, api_key_form(:openai_key))
                   |> put_flash(:info, "OpenAI connected and validated.")}

                {:error, _changeset} ->
                  {:noreply, put_flash(socket, :error, "Failed to save your OpenAI key.")}
              end

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "OpenAI key validation failed.")}
          end
        end)
    end
  end

  def handle_event("refresh_drives", _params, socket) do
    socket = assign(socket, :drives_loading, true)

    user_id = Context.current_user_id(socket)

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
        {:noreply, Loaders.load_connected_drives(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Drive not found.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle drive.")}
    end
  end

  def handle_event("connect_drive", %{"drive_id" => drive_id, "name" => name}, socket) do
    Context.with_linked_user(socket, fn _settings_user, user_id ->
      attrs = %{drive_id: drive_id, drive_name: name, drive_type: "shared"}

      case ConnectedDrives.connect(user_id, attrs) do
        {:ok, _drive} ->
          {:noreply,
           socket
           |> Loaders.load_connected_drives()
           |> put_flash(:info, "Connected #{name}.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to connect #{name}.")}
      end
    end)
  end

  def handle_event("connect_personal_drive", _params, socket) do
    Context.with_linked_user(socket, fn _settings_user, user_id ->
      case ConnectedDrives.ensure_personal_drive(user_id) do
        {:ok, _drive} ->
          {:noreply,
           socket
           |> Loaders.load_connected_drives()
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
         |> Loaders.load_connected_drives()
         |> put_flash(:info, "Drive disconnected.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to disconnect drive.")}
    end
  end

  def handle_event("open_model_modal", params, socket) do
    query =
      params
      |> Map.get("query", socket.assigns[:model_library_query] || "")
      |> to_string()
      |> String.trim()

    socket =
      socket
      |> assign(:model_modal_open, true)
      |> assign(:model_library_query, query)
      |> assign(:model_library_form, to_form(%{"q" => query}, as: :model_library))
      |> load_model_library()

    {:noreply, socket}
  end

  def handle_event("close_model_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:model_modal_open, false)
     |> assign(:model_library_error, nil)}
  end

  def handle_event("search_model_library", %{"model_library" => %{"q" => query}}, socket) do
    normalized_query = query |> to_string() |> String.trim()

    {:noreply,
     socket
     |> assign(:model_library_query, normalized_query)
     |> assign(:model_library_form, to_form(%{"q" => normalized_query}, as: :model_library))
     |> apply_model_library_filter()}
  end

  def handle_event("filter_active_models", %{"active_models" => params}, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()
    provider = params |> Map.get("provider", "all") |> to_string() |> String.trim() |> String.downcase()

    provider_options = socket.assigns[:active_model_provider_options] || [{"All providers", "all"}]
    allowed_providers = provider_options |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    normalized_provider = if MapSet.member?(allowed_providers, provider), do: provider, else: "all"
    all_models = socket.assigns[:active_model_all_models] || []

    {:noreply,
     socket
     |> assign(:active_model_query, query)
     |> assign(:active_model_provider, normalized_provider)
     |> assign(
       :active_model_filter_form,
       to_form(%{"q" => query, "provider" => normalized_provider}, as: :active_models)
     )
     |> assign(:models, Loaders.filter_active_models(all_models, query, normalized_provider))}
  end

  def handle_event("refresh_model_library", _params, socket) do
    {:noreply, load_model_library(socket)}
  end

  def handle_event("save_model", %{"model" => params}, socket) do
    case ModelCatalog.add_model(params) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> assign(:model_modal_open, false)
         |> Loaders.load_models()
         |> put_flash(:info, "Model catalog saved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save model: #{inspect(reason)}")}
    end
  end

  def handle_event("add_model_from_library", params, socket) do
    attrs = %{
      "id" => Map.get(params, "id", ""),
      "name" => Map.get(params, "name", ""),
      "input_cost" => Map.get(params, "input_cost", "n/a"),
      "output_cost" => Map.get(params, "output_cost", "n/a"),
      "max_context_tokens" => Map.get(params, "max_context_tokens", "n/a")
    }

    case ModelCatalog.add_model(attrs) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> Loaders.load_models()
         |> maybe_reload_model_library()
         |> put_flash(:info, "Model added to your catalog")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to add model: #{inspect(reason)}")}
    end
  end

  def handle_event("remove_model_from_catalog", %{"id" => model_id}, socket) do
    case ModelCatalog.remove_model(model_id) do
      :ok ->
        {:noreply,
         socket
         |> Loaders.load_models()
         |> maybe_reload_model_library()
         |> put_flash(:info, "Model removed from your catalog")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove model: #{inspect(reason)}")}
    end
  end

  def handle_event("save_model_defaults", %{"defaults" => params}, socket) do
    merged_defaults =
      ModelDefaults.list_defaults()
      |> Map.merge(params)

    case ModelDefaults.save_defaults(merged_defaults) do
      :ok ->
        {:noreply,
         socket
         |> Loaders.load_models()
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
         |> Loaders.load_skill_permissions()
         |> put_flash(:info, "#{SkillPermissions.skill_label(skill)} updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update permission: #{inspect(reason)}")}
    end
  end

  def handle_event("search_help", %{"help" => %{"q" => query}}, socket) do
    {:noreply, assign(socket, :help_query, query)}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    Profile.save_profile(socket, params, flash?: true)
  end

  def handle_event("autosave_profile", %{"profile" => params}, socket) do
    Profile.save_profile(socket, params, flash?: false)
  end

  def handle_event("autosave_orchestrator_prompt", %{"body" => body}, socket) do
    content = body |> to_string()
    socket = Profile.notify_autosave(socket, "saving", "Saving system instructions...")

    case OrchestratorSystemPrompt.save_prompt(content) do
      :ok ->
        {:noreply,
         socket
         |> assign(:orchestrator_prompt_text, content)
         |> assign(:orchestrator_prompt_html, Loaders.markdown_to_html(content))
         |> Profile.notify_autosave("saved", "All changes saved")}

      {:error, reason} ->
        {:noreply,
         socket
         |> Profile.notify_autosave("error", "Could not save system instructions")
         |> put_flash(:error, "Failed to save prompt: #{inspect(reason)}")}
    end
  end

  def handle_event("update_global_filters", %{"global" => params}, socket) do
    filters = normalize_graph_filters(params)

    socket =
      socket
      |> assign(:graph_filters, filters)
      |> assign(:graph_filters_form, to_form(filters, as: :global))
      |> assign(:selected_transcript, nil)
      |> assign(:selected_memory, nil)
      |> Loaders.load_memory_dashboard()

    {:noreply, push_event(socket, "render_graph", socket.assigns.graph_data)}
  end

  def handle_event("init_graph", _params, socket) do
    {:noreply, push_event(socket, "render_graph", socket.assigns.graph_data)}
  end

  def handle_event("expand_node", %{"node_id" => node_id}, socket) do
    graph_filters = socket.assigns.graph_filters || Data.blank_graph_filters()

    expanded_data =
      MemoryGraph.expand_node(socket.assigns[:current_scope], node_id, graph_filters)

    existing_data = socket.assigns.graph_data || %{nodes: [], links: []}
    existing_node_ids = socket.assigns.loaded_node_ids || MapSet.new()

    append_nodes =
      expanded_data.nodes
      |> Enum.reject(fn node -> MapSet.member?(existing_node_ids, Map.get(node, :id)) end)

    append_links = new_links(existing_data.links, expanded_data.links)

    graph_data = merge_graph_data(existing_data, %{nodes: append_nodes, links: append_links})

    loaded_node_ids =
      append_nodes
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reduce(existing_node_ids, &MapSet.put(&2, &1))

    socket =
      socket
      |> assign(:graph_data, graph_data)
      |> assign(:loaded_node_ids, loaded_node_ids)

    if append_nodes == [] and append_links == [] do
      {:noreply, socket}
    else
      {:noreply, push_event(socket, "append_graph", %{nodes: append_nodes, links: append_links})}
    end
  end

  def handle_event("filter_transcripts", %{"transcripts" => params}, socket) do
    filters = normalize_transcript_filters(params)

    {:noreply,
     socket
     |> assign(:transcript_filters, filters)
     |> assign(:transcript_filters_form, to_form(filters, as: :transcripts))
     |> assign(:selected_transcript, nil)
     |> Loaders.load_transcripts()}
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
     |> Loaders.load_memories()}
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

  defp normalize_transcript_filters(params) when is_map(params) do
    %{
      "query" => Map.get(params, "query", "") |> to_string() |> String.trim(),
      "channel" => Map.get(params, "channel", "") |> to_string() |> String.trim(),
      "status" => Map.get(params, "status", "") |> to_string() |> String.trim(),
      "agent_type" => Map.get(params, "agent_type", "") |> to_string() |> String.trim()
    }
  end

  defp normalize_transcript_filters(_), do: Data.blank_transcript_filters()

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

  defp normalize_memory_filters(_), do: Data.blank_memory_filters()

  defp normalize_graph_filters(params) when is_map(params) do
    defaults = Data.blank_graph_filters()
    timeframe_values = Data.graph_timeframe_values()
    type_values = Data.graph_type_values()

    timeframe =
      params
      |> Map.get("timeframe", defaults["timeframe"])
      |> to_string()
      |> String.trim()
      |> case do
        value ->
          if Enum.member?(timeframe_values, value) do
            value
          else
            defaults["timeframe"]
          end
      end

    type =
      params
      |> Map.get("type", defaults["type"])
      |> to_string()
      |> String.trim()
      |> case do
        value ->
          if Enum.member?(type_values, value) do
            value
          else
            defaults["type"]
          end
      end

    %{
      "query" => params |> Map.get("query", "") |> to_string() |> String.trim(),
      "timeframe" => timeframe,
      "type" => type
    }
  end

  defp normalize_graph_filters(_), do: Data.blank_graph_filters()

  defp merge_graph_data(existing, incoming) do
    nodes =
      unique_by_id((Map.get(existing, :nodes, []) || []) ++ (Map.get(incoming, :nodes, []) || []))

    links =
      unique_by_id((Map.get(existing, :links, []) || []) ++ (Map.get(incoming, :links, []) || []))

    %{nodes: nodes, links: links}
  end

  defp new_links(existing_links, expanded_links) do
    existing_ids =
      existing_links
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(expanded_links, fn link -> MapSet.member?(existing_ids, Map.get(link, :id)) end)
  end

  defp unique_by_id(items) do
    {list, _ids} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, ids} ->
        id = Map.get(item, :id)

        if is_nil(id) or MapSet.member?(ids, id) do
          {acc, ids}
        else
          {[item | acc], MapSet.put(ids, id)}
        end
      end)

    Enum.reverse(list)
  end

  defp api_key_form(form_name) do
    to_form(%{"api_key" => ""}, as: form_name)
  end

  defp load_model_library(socket) do
    query = socket.assigns[:model_library_query] || ""

    case openrouter_key_for_library(socket) do
      nil ->
        socket
        |> assign(:model_library_all_models, [])
        |> assign(:model_library_models, [])
        |> assign(
          :model_library_error,
          "Connect OpenRouter (or configure OPENROUTER_API_KEY) to browse available models."
        )

      api_key ->
        case OpenRouter.list_models_detailed(api_key) do
          {:ok, models} ->
            socket
            |> assign(:model_library_all_models, models)
            |> assign(:model_library_models, filter_library_models(models, query))
            |> assign(:model_library_error, nil)

          {:error, _reason} ->
            socket
            |> assign(:model_library_all_models, [])
            |> assign(:model_library_models, [])
            |> assign(
              :model_library_error,
              "Could not load OpenRouter models right now. Try again in a moment."
            )
        end
    end
  end

  defp openrouter_key_for_library(socket) do
    case Context.current_settings_user(socket) do
      %{openrouter_api_key: key} when is_binary(key) and key != "" ->
        key

      _ ->
        case Application.get_env(:assistant, :openrouter_api_key) do
          key when is_binary(key) and key != "" -> key
          _ -> nil
        end
    end
  end

  defp filter_library_models(models, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    models
    |> Enum.filter(fn model ->
      normalized == "" ||
        String.contains?(String.downcase(to_string(model.name)), normalized) ||
        String.contains?(String.downcase(to_string(model.id)), normalized)
    end)
    |> Enum.take(300)
  end

  defp apply_model_library_filter(socket) do
    query = socket.assigns[:model_library_query] || ""
    models = socket.assigns[:model_library_all_models] || []
    assign(socket, :model_library_models, filter_library_models(models, query))
  end

  defp maybe_reload_model_library(socket) do
    if socket.assigns[:model_modal_open] do
      load_model_library(socket)
    else
      socket
    end
  end
end
