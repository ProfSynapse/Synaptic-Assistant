defmodule AssistantWeb.SettingsLive.State do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, assign_new: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias AssistantWeb.Components.SettingsPage.Helpers, as: PageHelpers
  alias AssistantWeb.SettingsLive.Data
  alias AssistantWeb.SettingsLive.Loaders

  def init(socket) do
    socket
    |> assign_new(:current_scope, fn -> nil end)
    |> assign(:sidebar_collapsed, false)
    |> assign(:section, "profile")
    |> assign(:workflows, [])
    |> assign(:models, [])
    |> assign(:active_model_all_models, [])
    |> assign(:active_model_query, "")
    |> assign(:active_model_provider, "all")
    |> assign(:active_model_provider_options, [{"All providers", "all"}])
    |> assign(
      :active_model_filter_form,
      to_form(%{"q" => "", "provider" => "all"}, as: :active_models)
    )
    |> assign(:profile, Data.blank_profile())
    |> assign(:profile_form, to_form(Data.blank_profile(), as: :profile))
    |> assign(:orchestrator_prompt_text, "")
    |> assign(:orchestrator_prompt_html, "")
    |> assign(:model_options, [])
    |> assign(:model_defaults_mode, :readonly)
    |> assign(:model_defaults_editable, false)
    |> assign(:model_defaults_description, "")
    |> assign(:model_defaults_notice, "")
    |> assign(:model_default_sources, %{})
    |> assign(:model_defaults, %{})
    |> assign(:model_default_roles, [])
    |> assign(:model_defaults_form, to_form(%{}, as: :defaults))
    |> assign(:catalog_model_ids, MapSet.new())
    |> assign(:model_catalog_editable, false)
    |> assign(:model_modal_open, false)
    |> assign(:model_form, to_form(Data.blank_model_form(), as: :model))
    |> assign(:model_library_query, "")
    |> assign(:model_library_form, to_form(%{"q" => ""}, as: :model_library))
    |> assign(:model_library_all_models, [])
    |> assign(:model_library_models, [])
    |> assign(:model_library_error, nil)
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
    |> assign(:graph_filters, Data.blank_graph_filters())
    |> assign(:graph_filters_form, to_form(Data.blank_graph_filters(), as: :global))
    |> assign(:graph_filter_options, Data.graph_filter_options())
    |> assign(:loaded_node_ids, MapSet.new())
    |> assign(:graph_data, %{nodes: [], links: []})
    |> assign(:apps_modal_open, false)
    |> assign(:app_catalog, Data.app_catalog())
    |> assign(:admin_integration_catalog, Data.admin_integration_catalog())
    |> assign(:connected_storage_sources, [])
    |> assign(:available_storage_sources, [])
    |> assign(:storage_sources_loading, false)
    |> assign(:storage_scopes, [])
    |> assign(:file_picker_open, false)
    |> assign(:file_picker_provider, "google_drive")
    |> assign(:file_picker_mode, "scoped_tree")
    |> assign(:file_picker_selected_source, nil)
    |> assign(:file_picker_nodes, %{})
    |> assign(:file_picker_root_keys, [])
    |> assign(:file_picker_expanded, MapSet.new())
    |> assign(:file_picker_loading, false)
    |> assign(:file_picker_loading_nodes, MapSet.new())
    |> assign(:file_picker_error, nil)
    |> assign(:file_picker_selection_draft, %{})
    |> assign(:file_picker_pending_ops, [])
    |> assign(:file_picker_dirty, false)
    |> assign(:file_picker_continuations, %{})
    |> assign(:google_connected, false)
    |> assign(:google_email, nil)
    |> assign(:openrouter_connected, false)
    |> assign(:openai_connected, false)
    |> assign(:openrouter_key_form_open, false)
    |> assign(:openai_key_form_open, false)
    |> assign(:openrouter_key_form, to_form(%{"api_key" => ""}, as: :openrouter_key))
    |> assign(:openai_key_form, to_form(%{"api_key" => ""}, as: :openai_key))
    |> assign(:workspace_enabled_groups, %{})
    |> assign(:connector_states, %{})
    |> assign(:personal_skill_permissions, [])
    |> assign(:policy_approvals, [])
    |> assign(:policy_preset, "default")
    |> assign(:policy_preset_options, ["permissive", "default", "strict"])
    |> assign(:policy_rules, [])
    |> assign(:policy_api_available, false)
    |> assign(:help_articles, Data.help_articles())
    |> assign(:help_topic, nil)
    |> assign(:help_query, "")
    |> assign(:managed_scopes, [])
    |> assign(:admin_tab, "integrations")
    |> assign(:creating_new_user, false)
    |> assign(:can_bootstrap_admin, false)
    |> assign(:allowlist_form, to_form(%{}, as: "allowlist_entry"))
    |> assign(:allowlist_entries, [])
    |> assign(:admin_settings_users, [])
    |> assign(:admin_users_with_keys, [])
    |> assign(:filtered_admin_users, [])
    |> assign(:admin_user_search, "")
    |> assign(:current_admin_user, nil)
    |> assign(:integration_settings, [])
    |> assign(:connection_status, %{})
    |> assign(:current_app, nil)
    |> assign(:current_admin_integration, nil)
    |> assign(:app_integration_settings, [])
    |> assign(:telegram_bot_configured, false)
    |> assign(:telegram_enabled, false)
    |> assign(:telegram_identity, nil)
    |> assign(:telegram_connect_url, nil)
    |> assign(:telegram_bot_username, nil)
    |> assign(:telegram_connect_expires_at, nil)
    |> Loaders.load_profile()
    |> Loaders.load_orchestrator_prompt()
  end

  def handle_params(socket, params) do
    cond do
      Map.has_key?(params, "integration_group") ->
        handle_admin_integration(socket, params)

      Map.has_key?(params, "app_id") ->
        handle_app_detail(socket, params)

      true ->
        handle_section(socket, params)
    end
  end

  defp handle_section(socket, params) do
    section = Data.normalize_section(Map.get(params, "section", "profile"))

    is_admin =
      case socket.assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    current_scope = socket.assigns[:current_scope]
    section_scope = section_scope_name(section)

    cond do
      section == "admin" and not is_admin ->
        socket
        |> put_flash(:error, "You do not have permission to access admin.")
        |> push_navigate(to: "/settings")

      section_scope && current_scope &&
          not PageHelpers.scope_visible?(section_scope, current_scope) ->
        socket
        |> put_flash(:error, "Access denied.")
        |> push_navigate(to: "/settings")

      true ->
        help_topic = Map.get(params, "topic")

        socket
        |> assign(:section, section)
        |> assign(:current_app, nil)
        |> assign(:current_admin_integration, nil)
        |> assign(:telegram_connect_url, nil)
        |> assign(:telegram_bot_username, nil)
        |> assign(:telegram_connect_expires_at, nil)
        |> assign(:help_topic, Data.selected_help_article(section, help_topic))
        |> Loaders.load_section_data(section)
    end
  end

  defp handle_app_detail(socket, params) do
    app_id = Map.get(params, "app_id")

    case Data.find_app(app_id) do
      nil ->
        socket
        |> put_flash(:error, "App not found.")
        |> push_navigate(to: "/settings/apps")

      app ->
        socket
        |> assign(:section, "apps")
        |> assign(:current_app, app)
        |> assign(:current_admin_integration, nil)
        |> Loaders.load_app_detail_settings(app)
    end
  end

  defp handle_admin_integration(socket, params) do
    integration_group = Map.get(params, "integration_group")

    is_admin =
      case socket.assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    cond do
      not is_admin ->
        socket
        |> put_flash(:error, "You do not have permission to access admin.")
        |> push_navigate(to: "/settings")

      true ->
        case Data.find_admin_integration(integration_group) do
          nil ->
            socket
            |> put_flash(:error, "Integration not found.")
            |> push_navigate(to: "/settings/admin")

          integration ->
            socket
            |> assign(:section, "admin")
            |> assign(:current_app, nil)
            |> assign(:current_admin_integration, integration)
            |> assign(:help_topic, nil)
            |> Loaders.load_admin_integration_settings(integration.integration_group)
        end
    end
  end

  defp section_scope_name(section), do: PageHelpers.section_scope(section)
end
