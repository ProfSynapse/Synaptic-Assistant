defmodule AssistantWeb.SettingsLive.Data do
  @moduledoc false

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

  @blank_profile %{"display_name" => "", "email" => "", "timezone" => "UTC"}

  @blank_model_form %{
    "id" => "",
    "name" => "",
    "input_cost" => "",
    "output_cost" => "",
    "max_context_tokens" => ""
  }

  @blank_transcript_filters %{
    "query" => "",
    "channel" => "",
    "status" => "",
    "agent_type" => ""
  }

  @blank_transcript_filter_options %{channels: [], statuses: [], agent_types: []}

  @blank_memory_filters %{
    "query" => "",
    "category" => "",
    "source_type" => "",
    "tag" => "",
    "source_conversation_id" => ""
  }

  @blank_memory_filter_options %{categories: [], source_types: [], tags: []}

  def sections, do: @sections
  def app_catalog, do: @app_catalog
  def help_articles, do: @help_articles
  def empty_analytics, do: @empty_analytics
  def blank_profile, do: @blank_profile
  def blank_model_form, do: @blank_model_form
  def blank_transcript_filters, do: @blank_transcript_filters
  def blank_transcript_filter_options, do: @blank_transcript_filter_options
  def blank_memory_filters, do: @blank_memory_filters
  def blank_memory_filter_options, do: @blank_memory_filter_options

  def normalize_section(section) when section in @sections, do: section
  def normalize_section("general"), do: "profile"
  def normalize_section("transcripts"), do: "memory"
  def normalize_section(_), do: "profile"

  def selected_help_article("help", nil), do: nil
  def selected_help_article("help", slug), do: Enum.find(@help_articles, &(&1.slug == slug))
  def selected_help_article(_, _), do: nil
end
