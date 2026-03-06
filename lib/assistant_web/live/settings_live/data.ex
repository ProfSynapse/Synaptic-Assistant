defmodule AssistantWeb.SettingsLive.Data do
  @moduledoc false

  @sections ~w(profile analytics memory apps workflows admin help)
  @admin_integration_groups ~w(google_workspace telegram slack discord google_chat hubspot elevenlabs)

  @app_catalog [
    %{
      id: "google_workspace",
      name: "Google Workspace",
      icon_path: "/images/apps/google.svg",
      scopes: "Gmail, Calendar, Drive",
      summary: "Connect approved Google tools for email, calendars, and docs.",
      integration_group: "google_workspace",
      connect_type: :oauth,
      setup_instructions: [
        "Go to console.cloud.google.com/apis/credentials",
        "Create an OAuth 2.0 Client ID (Web application type)",
        "Add your callback URL to Authorized redirect URIs",
        "Copy the Client ID and Client Secret below, then click Connect to authorize"
      ],
      portal_url: "https://console.cloud.google.com/apis/credentials",
      docs_url: "https://developers.google.com/workspace/guides/create-credentials"
    },
    %{
      id: "telegram",
      name: "Telegram",
      icon_path: "/images/apps/telegram.svg",
      scopes: "Bot messages",
      summary: "Receive and respond to messages via a Telegram bot.",
      integration_group: "telegram",
      connect_type: :api_key,
      setup_instructions: [
        "Open @BotFather on Telegram",
        "Create a new bot with /newbot",
        "Copy the bot token provided by BotFather into this page",
        "Use the generated connect link to attach your Telegram account",
        "Only linked Telegram accounts will be able to chat with the bot"
      ],
      portal_url: "https://t.me/BotFather",
      docs_url: "https://core.telegram.org/bots/tutorial"
    },
    %{
      id: "slack",
      name: "Slack",
      icon_path: "/images/apps/slack.svg",
      scopes: "Channels, DMs",
      summary: "Read channel context and post workflow notifications.",
      integration_group: "slack",
      connect_type: :api_key,
      setup_instructions: [
        "Go to api.slack.com/apps and create a new app",
        "Under OAuth & Permissions, add required bot scopes",
        "Install the app to your workspace",
        "Copy the Bot Token (xoxb-...) from OAuth & Permissions",
        "Copy the Signing Secret from Basic Information",
        "Copy the Client ID and Client Secret from Basic Information"
      ],
      portal_url: "https://api.slack.com/apps",
      docs_url: "https://api.slack.com/authentication/basics"
    },
    %{
      id: "discord",
      name: "Discord",
      icon_path: "/images/apps/discord.svg",
      scopes: "Guilds, Messages",
      summary: "Interact via Discord bot with slash commands and messages.",
      integration_group: "discord",
      connect_type: :api_key,
      setup_instructions: [
        "Go to discord.com/developers/applications",
        "Create a new application",
        "Under Bot, create a bot and copy the token",
        "Copy the Public Key from General Information",
        "Copy the Application ID from General Information"
      ],
      portal_url: "https://discord.com/developers/applications",
      docs_url: "https://discord.com/developers/docs/intro"
    },
    %{
      id: "google_chat",
      name: "Google Chat",
      icon_path: "/images/apps/google-chat.svg",
      scopes: "Spaces, Messages",
      summary: "Send and receive messages in Google Chat spaces.",
      integration_group: "google_chat",
      connect_type: :api_key,
      setup_instructions: [
        "Step 1 — Create service account: Open Google Cloud Console -> IAM & Admin -> Service Accounts -> Create Service Account.",
        "Service account name: Synaptic Assistant Chat Bot",
        "Service account ID: synaptic-chat-bot (auto-fills from name)",
        "Description: Service account for Synaptic Assistant to send messages in Google Chat spaces",
        "Click Create and Continue.",
        "Step 2 — Roles: no additional project-level IAM roles are required for this integration.",
        "Click Continue (skip role assignment), then Done.",
        "Step 3 — Create JSON key: open the new service account, go to Keys, Add Key -> Create new key, select JSON, then Create.",
        "Copy the downloaded JSON contents into the Google Chat Service Account JSON field in Admin > Integrations > Google Chat.",
        "Copy your Google Cloud Project Number from Project Settings and save it in the Project Number field."
      ],
      portal_url: "https://console.cloud.google.com/iam-admin/serviceaccounts",
      docs_url: "https://developers.google.com/workspace/chat/authenticate-authorize-chat-app"
    },
    %{
      id: "hubspot",
      name: "HubSpot",
      icon_path: "/images/apps/hubspot.svg",
      scopes: "Contacts, Deals",
      summary: "Sync CRM tasks and account updates from HubSpot.",
      integration_group: "hubspot",
      connect_type: :api_key,
      setup_instructions: [
        "Go to app.hubspot.com",
        "Navigate to Settings → Integrations → Private Apps",
        "Create a new private app with required scopes",
        "Copy the access token"
      ],
      portal_url: "https://app.hubspot.com/settings",
      docs_url:
        "https://developers.hubspot.com/docs/guides/apps/private-apps/migrate-an-api-key-integration-to-a-private-app"
    },
    %{
      id: "elevenlabs",
      name: "ElevenLabs",
      icon_path: "/images/apps/elevenlabs.svg",
      scopes: "Text-to-Speech",
      summary: "Generate voice responses using ElevenLabs text-to-speech.",
      integration_group: "elevenlabs",
      connect_type: :api_key,
      setup_instructions: [
        "Go to elevenlabs.io",
        "Navigate to Profile → API Keys",
        "Generate and copy your API key",
        "Choose a voice from the Voice Library and copy its Voice ID"
      ],
      portal_url: "https://elevenlabs.io/app/settings/api-keys",
      docs_url: "https://elevenlabs.io/docs/eleven-api/quickstart"
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
      slug: "personal-tool-access",
      title: "Personal Tool Access Guide",
      summary: "Enable or disable skills for your own account.",
      body: [
        "Open Apps & Connections and click the settings icon on any card.",
        "Use Personal Tool Access to toggle model skills for your account.",
        "Disabled skills are blocked at runtime for sub-agents and memory agent."
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

  @blank_graph_filters %{
    "query" => "",
    "timeframe" => "30d",
    "type" => "all"
  }

  @graph_filter_options %{
    timeframes: [
      {"Last 24 hours", "24h"},
      {"Last 7 days", "7d"},
      {"Last 30 days", "30d"},
      {"Last 90 days", "90d"},
      {"All time", "all"}
    ],
    types: [
      {"All data", "all"},
      {"Entities", "entities"},
      {"Memories", "memories"},
      {"Transcripts", "transcripts"}
    ]
  }

  def sections, do: @sections
  def app_catalog, do: @app_catalog
  def find_app(app_id), do: Enum.find(@app_catalog, &(&1.id == app_id))

  def admin_integration_catalog,
    do: Enum.filter(@app_catalog, &(&1.integration_group in @admin_integration_groups))

  def find_admin_integration(integration_group) do
    Enum.find(admin_integration_catalog(), &(&1.integration_group == integration_group))
  end

  def help_articles, do: @help_articles
  def empty_analytics, do: @empty_analytics
  def blank_profile, do: @blank_profile
  def blank_model_form, do: @blank_model_form
  def blank_transcript_filters, do: @blank_transcript_filters
  def blank_transcript_filter_options, do: @blank_transcript_filter_options
  def blank_memory_filters, do: @blank_memory_filters
  def blank_memory_filter_options, do: @blank_memory_filter_options
  def blank_graph_filters, do: @blank_graph_filters
  def graph_filter_options, do: @graph_filter_options
  def graph_timeframe_values, do: Enum.map(@graph_filter_options.timeframes, &elem(&1, 1))
  def graph_type_values, do: Enum.map(@graph_filter_options.types, &elem(&1, 1))

  def timeframe_since("24h"), do: DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)
  def timeframe_since("7d"), do: DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)
  def timeframe_since("30d"), do: DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)
  def timeframe_since("90d"), do: DateTime.add(DateTime.utc_now(), -90 * 24 * 60 * 60, :second)
  def timeframe_since("all"), do: nil
  def timeframe_since(_), do: nil

  def normalize_section(section) when section in @sections, do: section
  def normalize_section("general"), do: "profile"
  def normalize_section("transcripts"), do: "memory"
  def normalize_section(_), do: "profile"

  def selected_help_article("help", nil), do: nil
  def selected_help_article("help", slug), do: Enum.find(@help_articles, &(&1.slug == slug))
  def selected_help_article(_, _), do: nil
end
