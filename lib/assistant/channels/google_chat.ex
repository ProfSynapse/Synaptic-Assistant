# lib/assistant/channels/google_chat.ex — Google Chat channel adapter.
#
# Converts raw Google Chat webhook events into the normalized
# Channels.Message struct and delegates replies to the Google Chat
# REST API client.
#
# Supports two event formats:
#   - v1 (legacy Chat API): top-level "type", "message", "user", "space" keys
#   - v2 (Workspace Add-on): nested under "chat" key with payload-based event
#     detection (messagePayload, addedToSpacePayload, appCommandPayload, etc.)
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour this module implements)
#   - lib/assistant/channels/message.ex (normalized message struct)
#   - lib/assistant/integrations/google/chat.ex (REST client for sending)
#   - lib/assistant_web/controllers/google_chat_controller.ex (consumer)

defmodule Assistant.Channels.GoogleChat do
  @moduledoc """
  Google Chat channel adapter.

  Implements `Assistant.Channels.Adapter` to normalize incoming Google Chat
  webhook events into `%Assistant.Channels.Message{}` structs and send
  replies via the Google Chat REST API.

  ## Supported Event Formats

  ### v1 (Legacy Chat API)

  Top-level keys: `"type"`, `"message"`, `"user"`, `"space"`, `"eventTime"`.

  ### v2 (Workspace Add-on)

  Nested under `"chat"` key. Event type is deduced from which payload key
  is present (`"messagePayload"`, `"addedToSpacePayload"`, etc.). User info
  lives at `chat["user"]`, space/message data inside the payload objects.

  ## Supported Event Types

    * `MESSAGE` / `messagePayload` - Direct message or @mention in a space
    * `APP_COMMAND` / `appCommandPayload` - Slash command invocation
    * `ADDED_TO_SPACE` / `addedToSpacePayload` - Bot added to a space or DM
    * `REMOVED_FROM_SPACE` / `removedFromSpacePayload` - Bot removed (ignored)

  ## Ignored Event Types

    * `REMOVED_FROM_SPACE` / `removedFromSpacePayload` - No action needed
    * All other types - Unhandled (cards, widgets, etc.)
  """

  @behaviour Assistant.Channels.Adapter

  require Logger

  alias Assistant.Channels.Message
  alias Assistant.Integrations.Google.Chat, as: ChatClient

  @impl true
  def channel_name, do: :google_chat

  @impl true
  @doc """
  Convert a raw Google Chat event map into a normalized Message struct.

  Detects v1 (top-level `"type"` key) vs v2 (nested `"chat"` key) format
  automatically and normalizes both into the same `%Message{}` struct.

  Returns `{:ok, message}` for MESSAGE, APP_COMMAND, and ADDED_TO_SPACE events.
  Returns `{:error, :ignored}` for REMOVED_FROM_SPACE and unrecognized events.
  """
  @spec normalize(map()) :: {:ok, Message.t()} | {:error, :ignored}

  # --- v2 (Workspace Add-on) format: event data nested under "chat" key ---
  # Note: appCommandPayload is checked before messagePayload because v2 app
  # command events may include BOTH keys (the messagePayload carries the
  # triggering message). The more specific payload takes priority.

  def normalize(%{"chat" => %{"appCommandPayload" => _payload} = chat} = _event) do
    normalize_v2_app_command(chat)
  end

  def normalize(%{"chat" => %{"messagePayload" => _payload} = chat} = _event) do
    normalize_v2_message(chat)
  end

  def normalize(%{"chat" => %{"addedToSpacePayload" => _payload} = chat} = _event) do
    normalize_v2_added_to_space(chat)
  end

  def normalize(%{"chat" => %{"removedFromSpacePayload" => _payload}}) do
    Logger.debug("Google Chat v2 REMOVED_FROM_SPACE — ignoring")
    {:error, :ignored}
  end

  def normalize(%{"chat" => chat} = event) do
    Logger.warning(
      "Google Chat v2 event ignored: chat_keys=#{inspect(Map.keys(chat))} top_keys=#{inspect(Map.keys(event))}"
    )

    {:error, :ignored}
  end

  # --- v1 (Legacy Chat API) format: top-level "type" key ---

  def normalize(%{"type" => "MESSAGE"} = event) do
    normalize_v1_message_event(event)
  end

  def normalize(%{"type" => "APP_COMMAND"} = event) do
    normalize_v1_message_event(event)
  end

  def normalize(%{"type" => "ADDED_TO_SPACE"} = event) do
    normalize_v1_added_to_space(event)
  end

  def normalize(%{"type" => "REMOVED_FROM_SPACE"}) do
    {:error, :ignored}
  end

  def normalize(event) do
    Logger.warning(
      "Google Chat event ignored: type=#{inspect(event["type"])} keys=#{inspect(Map.keys(event))}"
    )

    {:error, :ignored}
  end

  @impl true
  @doc """
  Send a text reply to a Google Chat space.

  Delegates to `Assistant.Integrations.Google.Chat.send_message/3`.
  """
  @spec send_reply(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_reply(space_id, text, opts \\ []) do
    case ChatClient.send_message(space_id, text, opts) do
      {:ok, _response} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Detect whether the original raw event was in v2 (Workspace Add-on) format.

  Used by the controller to determine the correct response envelope format.
  v2 events require the `hostAppDataAction` wrapper; v1 events use a flat
  `%{"text" => "..."}` response.
  """
  @spec v2_format?(map()) :: boolean()
  def v2_format?(%{"chat" => _}), do: true
  def v2_format?(_), do: false

  @doc """
  Wrap a text response in the correct JSON envelope for the event format.

  v1 format returns `%{"text" => text}`.
  v2 (Workspace Add-on) format returns the `hostAppDataAction` wrapper.
  """
  @spec wrap_response(String.t(), map()) :: map()
  def wrap_response(text, raw_event) do
    if v2_format?(raw_event) do
      %{
        "hostAppDataAction" => %{
          "chatDataAction" => %{
            "createMessageAction" => %{
              "message" => %{"text" => text}
            }
          }
        }
      }
    else
      %{"text" => text}
    end
  end

  # --- v2 Normalizers ---

  defp normalize_v2_message(chat) do
    payload = chat["messagePayload"] || %{}
    message = payload["message"] || %{}
    user = chat["user"] || message["sender"] || %{}
    space = payload["space"] || %{}
    thread = get_in(message, ["thread", "name"])

    slash_command = extract_slash_command(message)
    content = message["argumentText"] || message["text"] || ""

    {:ok,
     %Message{
       id: generate_id(),
       channel: :google_chat,
       channel_message_id: message["name"] || "",
       space_id: space["name"] || "",
       thread_id: thread,
       user_id: user["name"] || "",
       user_display_name: user["displayName"],
       user_email: user["email"],
       content: String.trim(content),
       argument_text: message["argumentText"],
       slash_command: slash_command,
       attachments: extract_attachments(message),
       metadata: %{
         "event_type" => "MESSAGE",
         "space_type" => space["type"],
         "event_time" => chat["eventTime"],
         "format" => "v2"
       },
       timestamp: parse_timestamp(chat["eventTime"])
     }}
  end

  defp normalize_v2_app_command(chat) do
    # v2 appCommandPayload contains appCommandMetadata and may also have
    # a messagePayload sibling with the triggering message
    payload = chat["appCommandPayload"] || %{}
    _command_metadata = payload["appCommandMetadata"] || %{}

    # The message may be in a sibling messagePayload or embedded
    message_payload = chat["messagePayload"] || %{}
    message = message_payload["message"] || %{}
    user = chat["user"] || message["sender"] || %{}
    space = message_payload["space"] || %{}
    thread = get_in(message, ["thread", "name"])

    slash_command = extract_slash_command(message)
    content = message["argumentText"] || message["text"] || ""

    {:ok,
     %Message{
       id: generate_id(),
       channel: :google_chat,
       channel_message_id: message["name"] || "",
       space_id: space["name"] || "",
       thread_id: thread,
       user_id: user["name"] || "",
       user_display_name: user["displayName"],
       user_email: user["email"],
       content: String.trim(content),
       argument_text: message["argumentText"],
       slash_command: slash_command,
       attachments: extract_attachments(message),
       metadata: %{
         "event_type" => "APP_COMMAND",
         "space_type" => space["type"],
         "event_time" => chat["eventTime"],
         "format" => "v2"
       },
       timestamp: parse_timestamp(chat["eventTime"])
     }}
  end

  defp normalize_v2_added_to_space(chat) do
    payload = chat["addedToSpacePayload"] || %{}
    user = chat["user"] || %{}
    space = payload["space"] || %{}

    {:ok,
     %Message{
       id: generate_id(),
       channel: :google_chat,
       channel_message_id: "",
       space_id: space["name"] || "",
       thread_id: nil,
       user_id: user["name"] || "",
       user_display_name: user["displayName"],
       user_email: user["email"],
       content: "",
       argument_text: nil,
       slash_command: nil,
       metadata: %{
         "event_type" => "ADDED_TO_SPACE",
         "space_type" => space["type"],
         "space_display_name" => space["displayName"],
         "format" => "v2"
       },
       timestamp: parse_timestamp(chat["eventTime"])
     }}
  end

  # --- v1 Normalizers ---

  defp normalize_v1_message_event(event) do
    message = event["message"] || %{}
    user = event["user"] || message["sender"] || %{}
    space = event["space"] || %{}
    thread = get_in(message, ["thread", "name"])

    slash_command = extract_slash_command(message)
    content = message["argumentText"] || message["text"] || ""

    {:ok,
     %Message{
       id: generate_id(),
       channel: :google_chat,
       channel_message_id: message["name"] || "",
       space_id: space["name"] || "",
       thread_id: thread,
       user_id: user["name"] || "",
       user_display_name: user["displayName"],
       user_email: user["email"],
       content: String.trim(content),
       argument_text: message["argumentText"],
       slash_command: slash_command,
       attachments: extract_attachments(message),
       metadata: %{
         "event_type" => event["type"],
         "space_type" => space["type"],
         "event_time" => event["eventTime"]
       },
       timestamp: parse_timestamp(event["eventTime"])
     }}
  end

  defp normalize_v1_added_to_space(event) do
    user = event["user"] || %{}
    space = event["space"] || %{}

    {:ok,
     %Message{
       id: generate_id(),
       channel: :google_chat,
       channel_message_id: "",
       space_id: space["name"] || "",
       thread_id: nil,
       user_id: user["name"] || "",
       user_display_name: user["displayName"],
       user_email: user["email"],
       content: "",
       argument_text: nil,
       slash_command: nil,
       metadata: %{
         "event_type" => "ADDED_TO_SPACE",
         "space_type" => space["type"],
         "space_display_name" => space["displayName"]
       },
       timestamp: parse_timestamp(event["eventTime"])
     }}
  end

  # --- Helpers ---

  # Extract the slash command name from annotations if present.
  defp extract_slash_command(%{"annotations" => annotations}) when is_list(annotations) do
    Enum.find_value(annotations, fn
      %{"type" => "SLASH_COMMAND", "slashCommand" => %{"commandName" => name}} -> name
      _ -> nil
    end)
  end

  defp extract_slash_command(_message), do: nil

  # Extract attachment metadata from the message (for future use).
  defp extract_attachments(%{"attachment" => attachments}) when is_list(attachments) do
    Enum.map(attachments, fn att ->
      %{
        "name" => att["attachmentDataRef"]["resourceName"],
        "content_type" => att["contentType"],
        "content_name" => att["contentName"]
      }
    end)
  end

  defp extract_attachments(_message), do: []

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp_str) when is_binary(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end

  defp generate_id do
    "gchat_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
