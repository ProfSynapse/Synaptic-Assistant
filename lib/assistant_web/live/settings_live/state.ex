defmodule AssistantWeb.SettingsLive.State do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, assign_new: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

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
    |> assign(:connected_drives, [])
    |> assign(:available_drives, [])
    |> assign(:drives_loading, false)
    |> assign(:sync_scopes, [])
    |> assign(:sync_target_browser_open, false)
    |> assign(:sync_target_drives, [])
    |> assign(:sync_target_selected_drive, "")
    |> assign(:sync_target_folders, [])
    |> assign(:sync_target_loading, false)
    |> assign(:sync_target_error, nil)
    |> assign(:google_connected, false)
    |> assign(:google_email, nil)
    |> assign(:openrouter_connected, false)
    |> assign(:openai_connected, false)
    |> assign(:openrouter_key_form_open, false)
    |> assign(:openai_key_form_open, false)
    |> assign(:openrouter_key_form, to_form(%{"api_key" => ""}, as: :openrouter_key))
    |> assign(:openai_key_form, to_form(%{"api_key" => ""}, as: :openai_key))
    |> assign(:skills_permissions, [])
    |> assign(:help_articles, Data.help_articles())
    |> assign(:help_topic, nil)
    |> assign(:help_query, "")
    |> assign(:managed_scopes, [])
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

    if section == "admin" and not is_admin do
      socket
      |> put_flash(:error, "You do not have permission to access admin.")
      |> push_navigate(to: "/settings")
    else
      help_topic = Map.get(params, "topic")

      socket
      |> assign(:section, section)
      |> assign(:current_app, nil)
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
        |> Loaders.load_app_detail_settings(app)
    end
  end
end
