defmodule AssistantWeb.SettingsLive.State do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, assign_new: 3, to_form: 2]

  alias AssistantWeb.SettingsLive.Data
  alias AssistantWeb.SettingsLive.Loaders

  def init(socket) do
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
    |> assign(:google_connected, false)
    |> assign(:google_email, nil)
    |> assign(:openrouter_connected, false)
    |> assign(:skills_permissions, [])
    |> assign(:help_articles, Data.help_articles())
    |> assign(:help_topic, nil)
    |> assign(:help_query, "")
    |> Loaders.load_profile()
    |> Loaders.load_orchestrator_prompt()
  end

  def handle_params(socket, params) do
    section = Data.normalize_section(Map.get(params, "section", "profile"))
    help_topic = Map.get(params, "topic")

    socket
    |> assign(:section, section)
    |> assign(:help_topic, Data.selected_help_article(section, help_topic))
    |> Loaders.load_section_data(section)
  end
end
