defmodule AssistantWeb.SettingsLive.Loaders do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Assistant.Analytics
  alias Assistant.Auth.TokenStore
  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.ConnectedDrives
  alias Assistant.Integrations.OpenAI
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

  def load_section_data(socket, "profile"),
    do: socket |> load_profile() |> load_orchestrator_prompt()

  def load_section_data(socket, "workflows"), do: reload_workflows(socket)
  def load_section_data(socket, "models"), do: load_models(socket)
  def load_section_data(socket, "analytics"), do: load_analytics(socket)
  def load_section_data(socket, "memory"), do: load_memory_dashboard(socket)

  def load_section_data(socket, "apps"),
    do: socket |> load_google_status() |> load_openrouter_status() |> load_connected_drives()

  def load_section_data(socket, "skills"), do: load_skill_permissions(socket)
  def load_section_data(socket, _section), do: socket

  def reload_workflows(socket) do
    case Workflows.list_workflows() do
      {:ok, workflows} -> assign(socket, :workflows, workflows)
      {:error, _reason} -> assign(socket, :workflows, [])
    end
  end

  def load_models(socket) do
    {openrouter_key, openai_key, openai_auth_type} = provider_keys(socket)
    openrouter_connected = present?(openrouter_key)
    openai_connected = present?(openai_key)
    catalog_ids = ModelCatalog.catalog_model_ids()

    models =
      ModelCatalog.list_models()
      |> filter_models_for_connected_providers(openrouter_connected, openai_connected)
      |> filter_models_by_provider_availability(openrouter_key, openai_key, openai_auth_type)

    roles = model_roles()
    explicit_defaults = ModelDefaults.list_defaults()

    current_defaults =
      Enum.reduce(roles, %{}, fn role, acc ->
        key = Atom.to_string(role.key)
        value = Map.get(explicit_defaults, key) || resolved_default_model_id(role.key)
        Map.put(acc, key, value || "")
      end)

    options = model_options_with_unavailable_defaults(models, current_defaults)

    socket
    |> assign(:openrouter_connected, openrouter_connected)
    |> assign(:openai_connected, openai_connected)
    |> assign(:catalog_model_ids, catalog_ids)
    |> assign(:models, models)
    |> assign(:model_options, options)
    |> assign(:model_defaults, current_defaults)
    |> assign(:model_default_roles, roles)
    |> assign(:model_defaults_form, to_form(current_defaults, as: :defaults))
  end

  def load_analytics(socket) do
    snapshot = Analytics.dashboard_snapshot(window_days: 7)
    assign(socket, :analytics_snapshot, snapshot)
  rescue
    _ ->
      assign(socket, :analytics_snapshot, Data.empty_analytics())
  end

  def load_memory_dashboard(socket) do
    socket
    |> load_transcripts()
    |> load_memories()
    |> load_memory_graph()
  end

  def load_transcripts(socket) do
    filters = socket.assigns.transcript_filters || %{}
    global_filters = socket.assigns.graph_filters || Data.blank_graph_filters()
    since = Data.timeframe_since(Map.get(global_filters, "timeframe", "30d"))
    type = Map.get(global_filters, "type", "all")

    query_opts = [
      query: merged_query(Map.get(filters, "query", ""), Map.get(global_filters, "query", "")),
      channel: Map.get(filters, "channel", ""),
      status: Map.get(filters, "status", ""),
      agent_type: Map.get(filters, "agent_type", ""),
      since: since,
      limit: 60
    ]

    options = Transcripts.filter_options()

    transcripts =
      if type in ["all", "transcripts"] do
        Transcripts.list_transcripts(query_opts)
      else
        []
      end

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

  def load_memories(socket) do
    filters = socket.assigns.memory_filters || %{}
    user_id = Context.current_user_id(socket)
    global_filters = socket.assigns.graph_filters || Data.blank_graph_filters()
    since = Data.timeframe_since(Map.get(global_filters, "timeframe", "30d"))
    type = Map.get(global_filters, "type", "all")

    query_opts = [
      user_id: user_id,
      query: merged_query(Map.get(filters, "query", ""), Map.get(global_filters, "query", "")),
      category: Map.get(filters, "category", ""),
      source_type: Map.get(filters, "source_type", ""),
      tag: Map.get(filters, "tag", ""),
      source_conversation_id: Map.get(filters, "source_conversation_id", ""),
      since: since,
      limit: 80
    ]

    options = MemoryExplorer.filter_options(user_id: user_id)

    memories =
      if type in ["all", "memories"] do
        MemoryExplorer.list_memories(query_opts)
      else
        []
      end

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

  def load_memory_graph(socket) do
    graph_filters = socket.assigns.graph_filters || Data.blank_graph_filters()
    graph_data = MemoryGraph.get_initial_graph(socket.assigns[:current_scope], graph_filters)
    loaded_node_ids = graph_data.nodes |> Enum.map(&Map.get(&1, :id)) |> MapSet.new()

    socket
    |> assign(:graph_data, graph_data)
    |> assign(:loaded_node_ids, loaded_node_ids)
  rescue
    _ ->
      socket
      |> assign(:graph_data, %{nodes: [], links: []})
      |> assign(:loaded_node_ids, MapSet.new())
  end

  def load_skill_permissions(socket) do
    assign(socket, :skills_permissions, SkillPermissions.list_permissions())
  end

  def load_google_status(socket) do
    case Context.current_settings_user(socket) do
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

  def load_openrouter_status(socket) do
    case Context.current_settings_user(socket) do
      %{openrouter_api_key: key} when not is_nil(key) and key != "" ->
        assign(socket, :openrouter_connected, true)

      _ ->
        assign(socket, :openrouter_connected, false)
    end
  rescue
    _ -> socket
  end

  def load_openai_status(socket) do
    case Context.current_settings_user(socket) do
      %{openai_api_key: key} when not is_nil(key) and key != "" ->
        assign(socket, :openai_connected, true)

      _ ->
        assign(socket, :openai_connected, false)
    end
  rescue
    _ -> socket
  end

  def load_connected_drives(socket) do
    case Context.current_user_id(socket) do
      nil ->
        socket

      user_id ->
        drives = ConnectedDrives.list_for_user(user_id)
        assign(socket, :connected_drives, drives)
    end
  rescue
    _ -> socket
  end

  def load_profile(socket) do
    profile =
      case Context.current_settings_user(socket) do
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

  def load_orchestrator_prompt(socket) do
    prompt = OrchestratorSystemPrompt.get_prompt()

    socket
    |> assign(:orchestrator_prompt_text, prompt)
    |> assign(:orchestrator_prompt_html, markdown_to_html(prompt))
  end

  def markdown_to_html(markdown) when is_binary(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _messages} -> html
      _ -> ""
    end
  end

  def markdown_to_html(_), do: ""

  def model_to_form_data(id) do
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

  defp model_roles do
    [
      %{
        key: :orchestrator,
        label: "Orchestrator",
        tooltip: "Top-level coordinator for each user request."
      },
      %{
        key: :sub_agent,
        label: "Subagents",
        tooltip: "Worker agents dispatched by the orchestrator."
      },
      %{
        key: :sentinel,
        label: "Sentinel",
        tooltip: "Guardrail model used for policy and risk checks."
      },
      %{
        key: :compaction,
        label: "Memory",
        tooltip: "Internally mapped to the compaction model role."
      }
    ]
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

  defp provider_keys(socket) do
    case Context.current_settings_user(socket) do
      %{
        openrouter_api_key: openrouter_key,
        openai_api_key: openai_key,
        openai_auth_type: openai_auth_type
      } ->
        {openrouter_key, openai_key, openai_auth_type}

      _ ->
        {nil, nil, nil}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp filter_models_for_connected_providers(models, true, _openai_connected), do: models

  defp filter_models_for_connected_providers(models, false, true) do
    Enum.filter(models, fn model -> openai_prefixed_model?(model.id) end)
  end

  defp filter_models_for_connected_providers(models, false, false), do: models

  defp filter_models_by_provider_availability(
         models,
         openrouter_key,
         openai_key,
         openai_auth_type
       ) do
    openrouter_available =
      if present?(openrouter_key) do
        case safe_list_models(OpenRouter, openrouter_key) do
          {:ok, ids} -> MapSet.new(ids)
          {:error, _} -> nil
        end
      else
        nil
      end

    openai_available =
      if present?(openai_key) do
        if openai_auth_type == "oauth" do
          OpenAI.codex_model_ids() |> Enum.map(&"openai/#{&1}") |> MapSet.new()
        else
          case safe_list_models(OpenAI, openai_key) do
            {:ok, ids} -> MapSet.new(Enum.map(ids, &"openai/#{&1}"))
            {:error, _} -> nil
          end
        end
      else
        nil
      end

    models =
      maybe_append_openai_oauth_models(models, openai_available, openai_auth_type)

    Enum.filter(models, fn model ->
      cond do
        openai_prefixed_model?(model.id) ->
          has_openai = is_struct(openai_available, MapSet)
          has_openrouter = is_struct(openrouter_available, MapSet)

          if has_openai or has_openrouter do
            (has_openai and MapSet.member?(openai_available, model.id)) or
              (has_openrouter and MapSet.member?(openrouter_available, model.id))
          else
            true
          end

        is_struct(openrouter_available, MapSet) ->
          MapSet.member?(openrouter_available, model.id)

        true ->
          true
      end
    end)
    |> Enum.sort_by(&String.downcase(to_string(&1.name || &1.id)))
  end

  defp openai_prefixed_model?(id) when is_binary(id), do: String.starts_with?(id, "openai/")
  defp openai_prefixed_model?(_), do: false

  defp maybe_append_openai_oauth_models(models, openai_available, "oauth")
       when is_struct(openai_available, MapSet) do
    existing_ids =
      models
      |> Enum.map(& &1.id)
      |> MapSet.new()

    missing_models =
      openai_available
      |> MapSet.difference(existing_ids)
      |> Enum.map(&oauth_openai_model_entry/1)

    models ++ missing_models
  end

  defp maybe_append_openai_oauth_models(models, _openai_available, _openai_auth_type), do: models

  defp oauth_openai_model_entry("openai/" <> model_suffix) do
    %{
      id: "openai/" <> model_suffix,
      name: "OpenAI " <> humanize_model_id(model_suffix),
      input_cost: "n/a",
      output_cost: "n/a",
      max_context_tokens: "n/a"
    }
  end

  defp oauth_openai_model_entry(model_id) do
    %{
      id: model_id,
      name: humanize_model_id(model_id),
      input_cost: "n/a",
      output_cost: "n/a",
      max_context_tokens: "n/a"
    }
  end

  defp humanize_model_id(value) when is_binary(value) do
    value
    |> String.split("/")
    |> List.last()
    |> to_string()
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
    |> String.trim()
  end

  defp humanize_model_id(_), do: "Model"

  defp safe_list_models(module, api_key) do
    module.list_models(api_key)
  rescue
    _ -> {:error, :provider_unavailable}
  end

  defp merged_query(left, right) do
    values =
      [left, right]
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Enum.join(values, " ")
  end

  defp model_options_with_unavailable_defaults(models, current_defaults) do
    base_options =
      models
      |> Enum.map(fn model -> {model.name, model.id} end)

    available_ids =
      models
      |> Enum.map(& &1.id)
      |> MapSet.new()

    unavailable_default_options =
      current_defaults
      |> Map.values()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(available_ids, &1))
      |> Enum.map(fn id -> {"#{humanize_model_id(id)} (default unavailable)", id} end)

    (base_options ++ unavailable_default_options)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.sort_by(fn {label, _id} -> String.downcase(label) end)
  end
end
