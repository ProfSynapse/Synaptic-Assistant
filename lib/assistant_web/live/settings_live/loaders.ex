defmodule AssistantWeb.SettingsLive.Loaders do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]

  require Logger

  alias Assistant.Accounts
  alias Assistant.Accounts.{SettingsUser, SettingsUserAllowlistEntry}
  alias Assistant.Analytics
  alias Assistant.Auth.TokenStore
  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.ConnectionValidator
  alias Assistant.IntegrationSettings.Registry
  alias Assistant.Integrations.OpenAI
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Integrations.Telegram.AccountLink
  alias Assistant.MemoryExplorer
  alias Assistant.SettingsUserConnectorStates
  alias Assistant.SpendingLimits
  alias Assistant.Storage
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
  def load_section_data(socket, "analytics"), do: load_analytics(socket)
  def load_section_data(socket, "memory"), do: load_memory_dashboard(socket)

  def load_section_data(socket, "apps"),
    do:
      socket
      |> load_google_status()
      |> load_connected_storage_sources()
      |> load_available_storage_sources()
      |> load_storage_scopes()
      |> load_openrouter_status()
      |> load_apps_integration_settings()
      |> load_workspace_enabled_groups()
      |> load_connector_states()
      |> load_connection_status()

  def load_section_data(socket, "admin"), do: load_admin(socket)
  def load_section_data(socket, _section), do: socket

  def reload_workflows(socket) do
    case Workflows.list_workflows() do
      {:ok, workflows} -> assign(socket, :workflows, workflows)
      {:error, _reason} -> assign(socket, :workflows, [])
    end
  end

  def load_models(socket) do
    settings_user = Context.current_settings_user(socket)
    {openrouter_key, openai_key, openai_auth_type} = provider_keys(socket)
    openrouter_connected = present?(openrouter_key)
    openai_connected = present?(openai_key)
    catalog_ids = ModelCatalog.catalog_model_ids()

    models =
      ModelCatalog.list_models()
      |> filter_models_for_connected_providers(openrouter_connected, openai_connected)
      |> filter_models_by_provider_availability(openrouter_key, openai_key, openai_auth_type)

    mode = ModelDefaults.mode(settings_user)
    editable? = ModelDefaults.editable?(settings_user)
    model_data = model_defaults_editor_data(settings_user, models)

    {defaults_description, defaults_notice} = model_defaults_copy(mode)

    provider_options = active_model_provider_options(models)
    query = socket.assigns[:active_model_query] || ""

    provider =
      normalize_active_model_provider(socket.assigns[:active_model_provider], provider_options)

    filtered_models = filter_active_models(models, query, provider)

    socket
    |> assign(:openrouter_connected, openrouter_connected)
    |> assign(:openai_connected, openai_connected)
    |> assign(:catalog_model_ids, catalog_ids)
    |> assign(:model_catalog_editable, settings_user && settings_user.is_admin == true)
    |> assign(:active_model_all_models, models)
    |> assign(:models, filtered_models)
    |> assign(:active_model_provider, provider)
    |> assign(:active_model_provider_options, provider_options)
    |> assign(
      :active_model_filter_form,
      to_form(%{"q" => query, "provider" => provider}, as: :active_models)
    )
    |> assign(:model_options, model_data.model_options)
    |> assign(:model_defaults_mode, mode)
    |> assign(:model_defaults_editable, editable?)
    |> assign(:model_defaults_description, defaults_description)
    |> assign(:model_defaults_notice, defaults_notice)
    |> assign(:model_default_sources, model_data.model_default_sources)
    |> assign(:model_defaults, model_data.model_defaults)
    |> assign(:model_default_roles, model_data.model_default_roles)
    |> assign(:model_defaults_form, to_form(model_data.model_defaults, as: :defaults))
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

  def load_admin(socket) do
    settings_user = Context.current_settings_user(socket)
    can_bootstrap = Accounts.admin_bootstrap_available?()

    if settings_user && settings_user.is_admin do
      blank_form =
        %SettingsUserAllowlistEntry{}
        |> Accounts.change_settings_user_allowlist_entry(%{
          active: true,
          is_admin: false,
          scopes: []
        })
        |> to_form(as: "allowlist_entry")

      all_users = Accounts.list_settings_users_for_admin()
      search = socket.assigns[:admin_user_search] || ""

      socket
      |> assign(
        managed_scopes: Accounts.managed_access_scopes(),
        can_bootstrap_admin: can_bootstrap,
        allowlist_form: blank_form,
        allowlist_entries: Accounts.list_settings_user_allowlist_entries(),
        admin_settings_users: Accounts.list_admin_settings_users(),
        admin_users_with_keys: all_users,
        filtered_admin_users: filter_admin_users(all_users, search),
        integration_settings: IntegrationSettings.list_all()
      )
      |> load_admin_model_data()
      |> load_models()
      |> maybe_refresh_current_admin_user()
    else
      assign(socket,
        can_bootstrap_admin: can_bootstrap,
        managed_scopes: Accounts.managed_access_scopes(),
        allowlist_form: to_form(%{}, as: "allowlist_entry"),
        allowlist_entries: [],
        admin_settings_users: [],
        admin_users_with_keys: [],
        filtered_admin_users: [],
        integration_settings: []
      )
    end
  end

  defp load_admin_model_data(socket) do
    settings_user = Context.current_settings_user(socket)
    {openrouter_key, openai_key, _openai_auth_type} = provider_keys(socket)
    openrouter_connected = present?(openrouter_key)
    openai_connected = present?(openai_key)

    models = ModelCatalog.list_models()
    mode = ModelDefaults.mode(settings_user)
    model_data = model_defaults_editor_data(settings_user, models)

    {defaults_description, defaults_notice} = model_defaults_copy(mode)

    socket
    |> assign(:openrouter_connected, openrouter_connected)
    |> assign(:openai_connected, openai_connected)
    |> assign(:model_options, model_data.model_options)
    |> assign(:model_defaults_mode, mode)
    |> assign(:model_defaults_editable, ModelDefaults.editable?(settings_user))
    |> assign(:model_defaults_description, defaults_description)
    |> assign(:model_defaults_notice, defaults_notice)
    |> assign(:model_default_sources, model_data.model_default_sources)
    |> assign(:model_defaults, model_data.model_defaults)
    |> assign(:model_default_roles, model_data.model_default_roles)
    |> assign(:model_defaults_form, to_form(model_data.model_defaults, as: :defaults))
  end

  def reload_admin_users(socket) do
    all_users = Accounts.list_settings_users_for_admin()
    search = socket.assigns[:admin_user_search] || ""

    socket
    |> assign(:admin_users_with_keys, all_users)
    |> assign(:admin_settings_users, Accounts.list_admin_settings_users())
    |> assign(:filtered_admin_users, filter_admin_users(all_users, search))
    |> maybe_refresh_current_admin_user()
  end

  def admin_user_detail(user_id) when is_binary(user_id) do
    with {:ok, user} <- Accounts.get_user_for_admin(user_id),
         %SettingsUser{} = settings_user <- Accounts.get_settings_user(user_id) do
      spending_data = SpendingLimits.current_usage(user_id)
      spending_limit = SpendingLimits.get_spending_limit(user_id)

      {:ok,
       user
       |> Map.merge(admin_user_model_defaults(settings_user))
       |> Map.put(:spending_usage, spending_data)
       |> Map.put(:spending_limit, spending_limit)}
    else
      _ -> {:error, :not_found}
    end
  end

  def filter_admin_users(users, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    if normalized == "" do
      users
    else
      Enum.filter(users, fn user ->
        String.contains?(String.downcase(to_string(user.email)), normalized) ||
          String.contains?(String.downcase(to_string(user.display_name || "")), normalized)
      end)
    end
  end

  defp maybe_refresh_current_admin_user(socket) do
    case socket.assigns[:current_admin_user] do
      nil ->
        socket

      %{id: user_id} ->
        case admin_user_detail(user_id) do
          {:ok, user} -> assign(socket, :current_admin_user, user)
          {:error, :not_found} -> assign(socket, :current_admin_user, nil)
        end
    end
  end

  @non_ai_groups ~w(google_workspace telegram slack discord google_chat hubspot elevenlabs)

  def load_app_detail_settings(socket, app) do
    socket =
      socket
      |> assign(:app_integration_settings, [])
      |> load_personal_skill_permissions(integration_group: app.integration_group)
      |> maybe_load_google_workspace_app_detail(app)

    if app.id == "telegram" do
      load_telegram_app_detail(socket, Context.current_settings_user(socket))
    else
      socket
    end
  end

  def load_apps_integration_settings(socket) do
    settings_user = Context.current_settings_user(socket)

    if settings_user && settings_user.is_admin do
      assign(socket, :integration_settings, integration_settings_for_group(nil))
    else
      assign(socket, :integration_settings, [])
    end
  end

  def load_admin_integration_settings(socket, integration_group) do
    settings_user = Context.current_settings_user(socket)

    if settings_user && settings_user.is_admin do
      assign(socket, :integration_settings, integration_settings_for_group(integration_group))
    else
      assign(socket, :integration_settings, [])
    end
  end

  def load_connection_status(socket) do
    settings_user = Context.current_settings_user(socket)

    case settings_user do
      %{is_admin: true, user_id: uid} when not is_nil(uid) ->
        results = ConnectionValidator.validate_all(uid)
        assign(socket, :connection_status, results)

      %{is_admin: true} ->
        results = ConnectionValidator.validate_all(nil)
        assign(socket, :connection_status, results)

      _ ->
        # Non-admins get a lightweight check: configured groups show as
        # :not_connected (toggle-enabled) instead of running real API handshakes.
        results = lightweight_connection_status()
        assign(socket, :connection_status, results)
    end
  rescue
    e ->
      Logger.warning("Connection validation failed: #{Exception.message(e)}")
      assign(socket, :connection_status, %{})
  end

  defp load_telegram_app_detail(socket, settings_user) do
    user_id =
      case settings_user do
        %{user_id: value} when is_binary(value) -> value
        _ -> nil
      end

    telegram_enabled = IntegrationSettings.get(:telegram_enabled) != "false"
    telegram_bot_configured = present?(IntegrationSettings.get(:telegram_bot_token))

    telegram_identity =
      case AccountLink.linked_identity_for_user(user_id) do
        {:ok, identity} -> identity
        {:error, :not_connected} -> nil
      end

    socket
    |> assign(:telegram_enabled, telegram_enabled)
    |> assign(:telegram_bot_configured, telegram_bot_configured)
    |> assign(:telegram_identity, telegram_identity)
  end

  defp maybe_load_google_workspace_app_detail(socket, %{id: "google_workspace"}) do
    socket
    |> load_google_status()
    |> load_connected_storage_sources()
    |> load_available_storage_sources()
    |> load_storage_scopes()
  end

  defp maybe_load_google_workspace_app_detail(socket, _app), do: socket

  def load_workspace_enabled_groups(socket) do
    enabled_by_group =
      Registry.groups()
      |> Map.keys()
      |> Map.new(fn group ->
        enabled =
          case Registry.enabled_key_for_group(group) do
            nil ->
              true

            key ->
              IntegrationSettings.get(key) != "false"
          end

        {group, enabled}
      end)

    assign(socket, :workspace_enabled_groups, enabled_by_group)
  rescue
    _ -> assign(socket, :workspace_enabled_groups, %{})
  end

  def load_connector_states(socket) do
    states =
      case Context.current_user_id(socket) do
        nil ->
          %{}

        user_id ->
          user_id
          |> SettingsUserConnectorStates.list_for_user()
          |> Map.new(fn state -> {state.integration_group, state.enabled} end)
      end

    assign(socket, :connector_states, states)
  rescue
    _ -> assign(socket, :connector_states, %{})
  end

  def load_personal_skill_permissions(socket, opts \\ []) do
    integration_group = Keyword.get(opts, :integration_group)

    permissions =
      case Context.current_user_id(socket) do
        user_id when is_binary(user_id) ->
          SkillPermissions.list_permissions_for_user(user_id,
            integration_group: integration_group
          )

        _ ->
          SkillPermissions.list_permissions(integration_group: integration_group)
      end

    assign(socket, :personal_skill_permissions, permissions)
  rescue
    _ -> assign(socket, :personal_skill_permissions, [])
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

  def load_connected_storage_sources(socket) do
    case Context.current_user_id(socket) do
      nil ->
        assign(socket, :connected_storage_sources, [])

      user_id ->
        assign(
          socket,
          :connected_storage_sources,
          Storage.list_connected_sources(user_id, provider: "google_drive")
        )
    end
  rescue
    _ -> assign(socket, :connected_storage_sources, [])
  end

  def load_available_storage_sources(socket) do
    socket = assign(socket, :storage_sources_loading, false)

    case Context.current_user_id(socket) do
      nil ->
        assign(socket, :available_storage_sources, [])

      user_id ->
        case Storage.list_provider_sources(user_id, "google_drive") do
          {:ok, sources} ->
            assign(socket, :available_storage_sources, sources)

          _ ->
            assign(socket, :available_storage_sources, [])
        end
    end
  rescue
    _ -> assign(socket, :available_storage_sources, [])
  end

  def load_storage_scopes(socket) do
    case Context.current_user_id(socket) do
      nil ->
        assign(socket, :storage_scopes, [])

      user_id ->
        assign(socket, :storage_scopes, Storage.list_scopes(user_id, provider: "google_drive"))
    end
  rescue
    _ -> assign(socket, :storage_scopes, [])
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
        fallback_key: :orchestrator_fallback,
        label: "Orchestrator",
        tooltip: "Top-level coordinator for each user request."
      },
      %{
        key: :sub_agent,
        fallback_key: :sub_agent_fallback,
        label: "Subagents",
        tooltip: "Worker agents dispatched by the orchestrator."
      },
      %{
        key: :sentinel,
        fallback_key: :sentinel_fallback,
        label: "Sentinel",
        tooltip: "Guardrail model used for policy and risk checks."
      },
      %{
        key: :compaction,
        fallback_key: :compaction_fallback,
        label: "Memory",
        tooltip: "Internally mapped to the compaction model role."
      }
    ]
  end

  defp model_defaults_editor_data(settings_user, models) do
    roles = model_roles()
    effective_defaults = ModelDefaults.effective_defaults(settings_user)

    current_defaults =
      Enum.reduce(roles, %{}, fn role, acc ->
        primary_key = Atom.to_string(role.key)
        fallback_key = Atom.to_string(role.fallback_key)

        primary_value =
          Map.get(effective_defaults, primary_key) ||
            resolved_default_model_id(role.key, settings_user)

        fallback_value =
          Map.get(effective_defaults, fallback_key) ||
            resolved_default_model_id(role.fallback_key, settings_user)

        acc
        |> Map.put(primary_key, primary_value || "")
        |> Map.put(fallback_key, fallback_value || "")
      end)

    default_sources =
      Enum.reduce(roles, %{}, fn role, acc ->
        acc
        |> Map.put(
          Atom.to_string(role.key),
          ModelDefaults.source_for(settings_user, role.key)
        )
        |> Map.put(
          Atom.to_string(role.fallback_key),
          ModelDefaults.source_for(settings_user, role.fallback_key)
        )
      end)

    %{
      model_default_roles: roles,
      model_default_sources: default_sources,
      model_defaults: current_defaults,
      model_options: model_options_with_unavailable_defaults(models, current_defaults)
    }
  end

  defp admin_user_model_defaults(%SettingsUser{} = settings_user) do
    model_data = model_defaults_editor_data(settings_user, ModelCatalog.list_models())
    {description, notice} = admin_user_model_defaults_copy(settings_user)

    %{
      effective_model_defaults: model_data.model_defaults,
      model_default_roles: model_data.model_default_roles,
      model_default_sources: model_data.model_default_sources,
      model_options: model_data.model_options,
      model_defaults_description: description,
      model_defaults_notice: notice,
      model_defaults_editable: not settings_user.is_admin,
      model_defaults_resettable: map_size(ModelDefaults.user_defaults(settings_user)) > 0
    }
  end

  defp admin_user_model_defaults_copy(%SettingsUser{is_admin: true}) do
    {"Admin accounts use the app-wide defaults from the Admin section.",
     "User-specific overrides are disabled for admin accounts."}
  end

  defp admin_user_model_defaults_copy(%SettingsUser{can_manage_model_defaults: true}) do
    {"Set user-specific defaults for this account. Per-user overrides are enabled.",
     "Changes save automatically. Apply Global Defaults clears every user-specific override."}
  end

  defp admin_user_model_defaults_copy(%SettingsUser{}) do
    {"Set user-specific defaults for this account.",
     "Changes save automatically. Apply Global Defaults clears every user-specific override."}
  end

  defp resolved_default_model_id(role, settings_user) do
    try do
      case ConfigLoader.model_for(role, settings_user: settings_user) do
        nil -> nil
        model -> model.id
      end
    rescue
      _ -> nil
    end
  end

  defp model_defaults_copy(:global) do
    {"Choose the app-wide default model used for each system role.",
     "Changes save automatically."}
  end

  defp model_defaults_copy(:readonly) do
    {"Your admin controls these defaults. You're viewing the effective model currently applied to your account.",
     "Managed by your admin."}
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

  defp integration_settings_for_group(nil) do
    IntegrationSettings.list_all()
    |> Enum.filter(fn setting -> setting.group in @non_ai_groups end)
  end

  defp integration_settings_for_group(group) do
    IntegrationSettings.list_all()
    |> Enum.filter(fn setting -> setting.group == group and setting.group in @non_ai_groups end)
  end

  # Lightweight connection check for non-admin users: marks groups with any
  # configured key as :not_connected (enabling the toggle) without making real
  # API calls. Admins get full validate_all with real handshakes.
  defp lightweight_connection_status do
    configured =
      IntegrationSettings.list_all()
      |> Enum.filter(fn s -> s.source != :none and s.group in @non_ai_groups end)
      |> Enum.map(& &1.group)
      |> MapSet.new()

    @non_ai_groups
    |> Map.new(fn group ->
      status = if MapSet.member?(configured, group), do: :not_connected, else: :not_configured
      {group, status}
    end)
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

  def filter_active_models(models, query, provider) do
    normalized_query = query |> to_string() |> String.trim() |> String.downcase()
    normalized_provider = provider |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(models, fn model ->
      provider_match? =
        normalized_provider in ["", "all"] ||
          model_provider(model.id) == normalized_provider

      search_match? =
        normalized_query == "" ||
          String.contains?(String.downcase(to_string(model.name || "")), normalized_query) ||
          String.contains?(String.downcase(to_string(model.id || "")), normalized_query) ||
          String.contains?(String.downcase(model_provider(model.id)), normalized_query)

      provider_match? and search_match?
    end)
  end

  defp active_model_provider_options(models) do
    providers =
      models
      |> Enum.map(&model_provider(&1.id))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    [{"All providers", "all"} | Enum.map(providers, &{String.upcase(&1), &1})]
  end

  defp normalize_active_model_provider(provider, options) do
    normalized = provider |> to_string() |> String.trim() |> String.downcase()
    allowed = options |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    if MapSet.member?(allowed, normalized), do: normalized, else: "all"
  end

  defp model_provider(id) when is_binary(id) do
    id
    |> String.split("/", parts: 2)
    |> case do
      [provider, _rest] -> provider
      _ -> ""
    end
  end

  defp model_provider(_), do: ""
end
