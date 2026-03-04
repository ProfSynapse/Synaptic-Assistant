defmodule Assistant.IntegrationSettings.Registry do
  @moduledoc """
  Compile-time registry of valid integration keys.

  Defines all integration key groups with metadata: label, help text,
  environment variable mapping, and secret flag. The secret flag controls
  UI masking (all values are encrypted at rest regardless).
  """

  @type key_def :: %{
          key: atom(),
          secret: boolean(),
          env: String.t(),
          label: String.t(),
          help: String.t()
        }

  @groups %{
    "ai_providers" => %{
      label: "AI Providers",
      keys: [
        %{
          key: :openrouter_api_key,
          secret: true,
          env: "OPENROUTER_API_KEY",
          label: "OpenRouter API Key",
          help: "System fallback key from openrouter.ai/settings/keys"
        },
        %{
          key: :openai_api_key,
          secret: true,
          env: "OPENAI_API_KEY",
          label: "OpenAI API Key",
          help: "Optional direct provider key from platform.openai.com/api-keys"
        }
      ]
    },
    "models" => %{
      label: "Models",
      keys: [
        %{
          key: :model_default_orchestrator,
          secret: false,
          env: "",
          label: "Default Orchestrator Model",
          help: "App-wide fallback model for the orchestrator role"
        },
        %{
          key: :model_default_sub_agent,
          secret: false,
          env: "",
          label: "Default Sub-Agent Model",
          help: "App-wide fallback model for sub-agent runs"
        },
        %{
          key: :model_default_sentinel,
          secret: false,
          env: "",
          label: "Default Sentinel Model",
          help: "App-wide fallback model for policy and classification checks"
        },
        %{
          key: :model_default_compaction,
          secret: false,
          env: "",
          label: "Default Memory Model",
          help: "App-wide fallback model for compaction and memory summarization"
        }
      ]
    },
    "google_workspace" => %{
      label: "Google Workspace",
      keys: [
        %{
          key: :google_oauth_client_id,
          secret: true,
          env: "GOOGLE_OAUTH_CLIENT_ID",
          label: "OAuth Client ID",
          help: "Create at console.cloud.google.com/apis/credentials"
        },
        %{
          key: :google_oauth_client_secret,
          secret: true,
          env: "GOOGLE_OAUTH_CLIENT_SECRET",
          label: "OAuth Client Secret",
          help: "Same page as Client ID"
        },
        %{
          key: :google_workspace_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    },
    "telegram" => %{
      label: "Telegram",
      keys: [
        %{
          key: :telegram_bot_token,
          secret: true,
          env: "TELEGRAM_BOT_TOKEN",
          label: "Bot Token",
          help: "Get from @BotFather on Telegram"
        },
        %{
          key: :telegram_webhook_secret,
          secret: true,
          env: "TELEGRAM_WEBHOOK_SECRET",
          label: "Webhook Secret",
          help: "Random string for webhook verification"
        },
        %{
          key: :telegram_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    },
    "slack" => %{
      label: "Slack",
      keys: [
        %{
          key: :slack_client_id,
          secret: true,
          env: "SLACK_CLIENT_ID",
          label: "Client ID",
          help: "From api.slack.com/apps → OAuth & Permissions"
        },
        %{
          key: :slack_client_secret,
          secret: true,
          env: "SLACK_CLIENT_SECRET",
          label: "Client Secret",
          help: "Same page as Client ID"
        },
        %{
          key: :slack_bot_token,
          secret: true,
          env: "SLACK_BOT_TOKEN",
          label: "Bot Token",
          help: "xoxb-... token from OAuth & Permissions"
        },
        %{
          key: :slack_signing_secret,
          secret: true,
          env: "SLACK_SIGNING_SECRET",
          label: "Signing Secret",
          help: "From Basic Information → App Credentials"
        },
        %{
          key: :slack_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    },
    "discord" => %{
      label: "Discord",
      keys: [
        %{
          key: :discord_bot_token,
          secret: true,
          env: "DISCORD_BOT_TOKEN",
          label: "Bot Token",
          help: "From discord.com/developers/applications → Bot → Token"
        },
        %{
          key: :discord_public_key,
          secret: true,
          env: "DISCORD_PUBLIC_KEY",
          label: "Public Key",
          help: "From discord.com/developers/applications → General Information"
        },
        # Pre-provisioned for future slash command registration via Discord API.
        # Currently loaded into config but not consumed by application code.
        %{
          key: :discord_application_id,
          secret: false,
          env: "DISCORD_APPLICATION_ID",
          label: "Application ID",
          help: "From discord.com/developers/applications → General Information"
        },
        %{
          key: :discord_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    },
    "google_chat" => %{
      label: "Google Chat",
      keys: [
        %{
          key: :google_cloud_project_number,
          secret: false,
          env: "GOOGLE_CLOUD_PROJECT_NUMBER",
          label: "Project Number",
          help: "From Google Cloud Console → Dashboard → Project Info (numeric ID)"
        },
        %{
          key: :google_service_account_json,
          secret: true,
          env: "GOOGLE_SERVICE_ACCOUNT_JSON",
          label: "Service Account JSON",
          help:
            "Paste the full JSON key from GCP Console → IAM → Service Accounts → Keys, or set GOOGLE_SERVICE_ACCOUNT_JSON env var"
        },
        %{
          key: :google_chat_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    },
    "hubspot" => %{
      label: "HubSpot",
      keys: [
        %{
          key: :hubspot_api_key,
          secret: true,
          env: "HUBSPOT_API_KEY",
          label: "Private App Token",
          help: "From app.hubspot.com → Settings → Integrations → Private Apps"
        },
        %{
          key: :hubspot_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    },
    "elevenlabs" => %{
      label: "ElevenLabs",
      keys: [
        %{
          key: :elevenlabs_api_key,
          secret: true,
          env: "ELEVENLABS_API_KEY",
          label: "API Key",
          help: "From elevenlabs.io → Profile → API Keys"
        },
        %{
          key: :elevenlabs_voice_id,
          secret: false,
          env: "ELEVENLABS_VOICE_ID",
          label: "Voice ID",
          help: "From Voice Library → voice settings"
        },
        %{
          key: :elevenlabs_enabled,
          secret: false,
          env: "",
          label: "Enabled",
          help: "Enable or disable this integration"
        }
      ]
    }
  }

  # Build compile-time lookup maps for fast access
  @all_key_defs @groups
                |> Enum.flat_map(fn {group, %{keys: keys}} ->
                  Enum.map(keys, &Map.put(&1, :group, group))
                end)

  @key_to_def Map.new(@all_key_defs, fn def -> {def.key, def} end)
  @key_string_to_def Map.new(@all_key_defs, fn def -> {Atom.to_string(def.key), def} end)
  @key_to_env Map.new(@all_key_defs, fn def -> {def.key, def.env} end)
  @known_keys MapSet.new(@all_key_defs, & &1.key)
  @known_key_strings MapSet.new(@all_key_defs, &Atom.to_string(&1.key))

  @enabled_keys @all_key_defs
                |> Enum.filter(fn def ->
                  String.ends_with?(Atom.to_string(def.key), "_enabled")
                end)
                |> MapSet.new(& &1.key)

  @enabled_key_strings MapSet.new(@enabled_keys, &Atom.to_string/1)

  # Map from group string to the corresponding _enabled key atom
  @group_to_enabled_key @all_key_defs
                        |> Enum.filter(fn def -> MapSet.member?(@enabled_keys, def.key) end)
                        |> Map.new(fn def -> {def.group, def.key} end)

  @doc """
  Returns all groups with their metadata and keys.

  Each group is a `{group_id, %{label: String.t(), keys: [key_def()]}}` pair.
  """
  @spec groups() :: %{String.t() => %{label: String.t(), keys: [key_def()]}}
  def groups, do: @groups

  @doc """
  Returns key definitions for a specific group.

  Returns `nil` if the group does not exist.
  """
  @spec keys_for_group(String.t()) :: [key_def()] | nil
  def keys_for_group(group) do
    case Map.get(@groups, group) do
      nil -> nil
      %{keys: keys} -> keys
    end
  end

  @doc """
  Returns all key definitions across all groups, each augmented with `:group`.
  """
  @spec all_keys() :: [map()]
  def all_keys, do: @all_key_defs

  @doc """
  Returns the environment variable name for a given key atom.

  Returns `nil` if the key is not recognized.
  """
  @spec env_var_for_key(atom()) :: String.t() | nil
  def env_var_for_key(key) when is_atom(key), do: Map.get(@key_to_env, key)

  @doc """
  Returns the full definition for a given key.

  Accepts both atoms and strings. Returns `nil` if not recognized.
  """
  @spec definition_for_key(atom() | String.t()) :: map() | nil
  def definition_for_key(key) when is_atom(key), do: Map.get(@key_to_def, key)
  def definition_for_key(key) when is_binary(key), do: Map.get(@key_string_to_def, key)

  @doc """
  Returns true if the key is a recognized integration key.

  Accepts both atoms and strings.
  """
  @spec known_key?(atom() | String.t()) :: boolean()
  def known_key?(key) when is_atom(key), do: MapSet.member?(@known_keys, key)
  def known_key?(key) when is_binary(key), do: MapSet.member?(@known_key_strings, key)

  @doc """
  Returns true if the key is an `_enabled` toggle key.

  Accepts both atoms and strings.
  """
  @spec enabled_key?(atom() | String.t()) :: boolean()
  def enabled_key?(key) when is_atom(key), do: MapSet.member?(@enabled_keys, key)
  def enabled_key?(key) when is_binary(key), do: MapSet.member?(@enabled_key_strings, key)

  @doc """
  Returns the `_enabled` key atom for the given group string.

  Returns `nil` if the group has no `_enabled` key.
  """
  @spec enabled_key_for_group(String.t()) :: atom() | nil
  def enabled_key_for_group(group) when is_binary(group) do
    Map.get(@group_to_enabled_key, group)
  end
end
