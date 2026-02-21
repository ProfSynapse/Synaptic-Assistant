defmodule AssistantWeb.SettingsLive.Loaders do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Assistant.Analytics
  alias Assistant.Auth.TokenStore
  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.ConnectedDrives
  alias Assistant.MemoryExplorer
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
  def load_section_data(socket, "memory"), do: socket |> load_transcripts() |> load_memories()

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
    models = ModelCatalog.list_models()
    roles = model_roles()
    explicit_defaults = ModelDefaults.list_defaults()

    current_defaults =
      Enum.reduce(roles, %{}, fn role, acc ->
        key = Atom.to_string(role.key)
        value = Map.get(explicit_defaults, key) || resolved_default_model_id(role.key)
        Map.put(acc, key, value || "")
      end)

    options = Enum.map(models, fn model -> {model.name, model.id} end)

    socket
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

  def load_transcripts(socket) do
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

  def load_memories(socket) do
    filters = socket.assigns.memory_filters || %{}
    user_id = Context.current_user_id(socket)

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
end
