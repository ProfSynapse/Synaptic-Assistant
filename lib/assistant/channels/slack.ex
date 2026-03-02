# lib/assistant/channels/slack.ex — Slack channel adapter.
#
# Converts raw Slack Events API callback payloads into the normalized
# Channels.Message struct and delegates replies to the Slack Web API client.
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour this module implements)
#   - lib/assistant/channels/message.ex (normalized message struct)
#   - lib/assistant/integrations/slack/client.ex (Web API HTTP client)
#   - lib/assistant_web/controllers/slack_controller.ex (consumer)

defmodule Assistant.Channels.Slack do
  @moduledoc """
  Slack channel adapter.

  Implements `Assistant.Channels.Adapter` to normalize incoming Slack Events
  API callback payloads into `%Assistant.Channels.Message{}` structs and send
  replies via the Slack Web API.

  ## Supported Event Types

    * `message` — Direct messages and channel messages (no subtype)
    * `app_mention` — Bot mentions in channels

  ## Ignored Events

    * Messages with `subtype` (bot_message, message_changed, message_deleted, etc.)
    * Messages with `bot_id` present (prevents echo loops)
    * All other event types
  """

  @behaviour Assistant.Channels.Adapter

  alias Assistant.Channels.Message
  alias Assistant.IntegrationSettings
  alias Assistant.Integrations.Slack.Client

  @impl true
  def channel_name, do: :slack

  @impl true
  @doc """
  Convert a Slack event into a normalized Message struct.

  Expects the `event` object extracted from the Events API callback
  (not the full callback envelope — the controller extracts `params["event"]`).

  Returns `{:ok, message}` for processable message events.
  Returns `{:error, :ignored}` for bot messages, subtypes, and unknown events.
  """
  @spec normalize(map()) :: {:ok, Message.t()} | {:error, :ignored}

  # Ignore messages with subtypes (bot_message, message_changed, etc.)
  def normalize(%{"type" => type, "subtype" => _subtype})
      when type in ["message", "app_mention"] do
    {:error, :ignored}
  end

  # Ignore messages from bots (prevent echo loops)
  def normalize(%{"type" => type, "bot_id" => _bot_id})
      when type in ["message", "app_mention"] do
    {:error, :ignored}
  end

  # Regular message or app_mention with text
  def normalize(%{"type" => type, "text" => text} = event)
      when type in ["message", "app_mention"] and is_binary(text) do
    # team_id is injected by the controller from the event_callback envelope
    team_id = event["_team_id"] || event["team"]
    channel_id = event["channel"] || ""
    raw_user_id = event["user"] || ""
    cleaned_text = strip_bot_mention(text, type)

    {:ok,
     %Message{
       id: generate_id(),
       channel: :slack,
       channel_message_id: event["ts"] || "",
       space_id: scope_id(team_id, channel_id),
       thread_id: event["thread_ts"],
       user_id: scope_id(team_id, raw_user_id),
       user_display_name: nil,
       user_email: nil,
       content: String.trim(cleaned_text),
       argument_text: nil,
       slash_command: nil,
       attachments: [],
       metadata: %{
         "event_type" => type,
         "team" => team_id,
         "channel_type" => event["channel_type"]
       },
       timestamp: parse_timestamp(event["ts"])
     }}
  end

  # All other events
  def normalize(_event), do: {:error, :ignored}

  @impl true
  @doc """
  Send a text reply to a Slack channel.

  Looks up the bot token from opts (`:bot_token`) or falls back to app config.
  Maps the `thread_name` option to `thread_ts` for Slack threaded replies.
  """
  @spec send_reply(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_reply(channel_id, text, opts \\ []) do
    bot_token =
      Keyword.get(opts, :bot_token) ||
        IntegrationSettings.get(:slack_bot_token)

    if is_nil(bot_token) do
      {:error, :bot_token_not_configured}
    else
      client_opts =
        case Keyword.get(opts, :thread_name) do
          nil -> []
          thread_ts -> [thread_ts: thread_ts]
        end

      case Client.post_message(bot_token, channel_id, text, client_opts) do
        {:ok, _result} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  @doc "Returns the list of capabilities supported by Slack."
  def capabilities, do: [:typing, :threads, :rich_cards, :markdown_formatting]

  # --- Helpers ---

  # Build a globally-unique scoped ID: "slack:{team_id}:{local_id}"
  # Falls back to just the local_id when team_id is unavailable.
  defp scope_id(nil, local_id), do: local_id
  defp scope_id("", local_id), do: local_id
  defp scope_id(team_id, local_id), do: "slack:#{team_id}:#{local_id}"

  # Strip the leading bot mention from app_mention events.
  # Slack prefixes app_mention text with "<@U_BOTID> " — remove it so the
  # orchestrator receives the actual user intent.
  defp strip_bot_mention(text, "app_mention") do
    String.replace(text, ~r/^<@[A-Z0-9_]+>\s*/, "")
  end

  defp strip_bot_mention(text, _type), do: text

  # Slack timestamps are in "epoch.sequence" format (e.g., "1234567890.123456")
  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {float_ts, _} ->
        unix_seconds = trunc(float_ts)

        case DateTime.from_unix(unix_seconds) do
          {:ok, dt} -> dt
          {:error, _} -> nil
        end

      :error ->
        nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp generate_id do
    "slack_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
