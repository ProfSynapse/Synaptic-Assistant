# lib/assistant/channels/google_chat.ex — Google Chat channel adapter.
#
# Converts raw Google Chat webhook events into the normalized
# Channels.Message struct and delegates replies to the Google Chat
# REST API client.
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

  ## Supported Event Types

    * `MESSAGE` - Direct message or @mention in a space
    * `APP_COMMAND` - Slash command invocation
    * `ADDED_TO_SPACE` - Bot added to a space or DM (returns welcome intent)

  ## Ignored Event Types

    * `REMOVED_FROM_SPACE` - Bot removed (no action needed)
    * All other types - Unhandled (cards, widgets, etc.)
  """

  @behaviour Assistant.Channels.Adapter

  alias Assistant.Channels.Message
  alias Assistant.Integrations.Google.Chat, as: ChatClient

  @impl true
  def channel_name, do: :google_chat

  @impl true
  @doc """
  Convert a raw Google Chat event map into a normalized Message struct.

  Returns `{:ok, message}` for MESSAGE, APP_COMMAND, and ADDED_TO_SPACE events.
  Returns `{:error, :ignored}` for REMOVED_FROM_SPACE and unrecognized events.
  """
  @spec normalize(map()) :: {:ok, Message.t()} | {:error, :ignored}
  def normalize(%{"type" => "MESSAGE"} = event) do
    normalize_message_event(event)
  end

  def normalize(%{"type" => "APP_COMMAND"} = event) do
    normalize_message_event(event)
  end

  def normalize(%{"type" => "ADDED_TO_SPACE"} = event) do
    normalize_added_to_space(event)
  end

  def normalize(%{"type" => "REMOVED_FROM_SPACE"}) do
    {:error, :ignored}
  end

  def normalize(_event) do
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

  # --- Normalizers ---

  defp normalize_message_event(event) do
    message = event["message"] || %{}
    user = event["user"] || message["sender"] || %{}
    space = event["space"] || %{}
    thread = get_in(message, ["thread", "name"])

    # Extract slash command name if present
    slash_command = extract_slash_command(message)

    # Use argumentText when available (strips the @mention prefix),
    # fall back to full message text
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

  defp normalize_added_to_space(event) do
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
