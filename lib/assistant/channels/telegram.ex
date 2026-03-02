# lib/assistant/channels/telegram.ex — Telegram channel adapter.
#
# Converts raw Telegram webhook Update objects into the normalized
# Channels.Message struct and delegates replies to the Telegram Bot API client.
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour this module implements)
#   - lib/assistant/channels/message.ex (normalized message struct)
#   - lib/assistant/integrations/telegram/client.ex (Bot API HTTP client)
#   - lib/assistant_web/controllers/telegram_controller.ex (consumer)

defmodule Assistant.Channels.Telegram do
  @moduledoc """
  Telegram channel adapter.

  Implements `Assistant.Channels.Adapter` to normalize incoming Telegram
  webhook Update objects into `%Assistant.Channels.Message{}` structs and
  send replies via the Telegram Bot API.

  ## Supported Update Types

    * `message` with `text` — Regular text messages and bot commands
    * `message` with `text` starting with `/` — Bot commands (mapped to `slash_command`)

  ## Ignored Update Types

    * `edited_message` — Message edits
    * `channel_post` — Channel broadcasts
    * `callback_query` — Inline keyboard callbacks
    * All other update types (inline queries, polls, etc.)
  """

  @behaviour Assistant.Channels.Adapter

  alias Assistant.Channels.Message
  alias Assistant.Integrations.Telegram.Client

  @impl true
  def channel_name, do: :telegram

  @impl true
  @doc """
  Convert a raw Telegram Update object into a normalized Message struct.

  Returns `{:ok, message}` for text messages.
  Returns `{:error, :ignored}` for non-text updates.
  """
  @spec normalize(map()) :: {:ok, Message.t()} | {:error, :ignored}
  def normalize(%{"message" => %{"text" => text} = msg}) when is_binary(text) do
    chat = msg["chat"] || %{}
    from = msg["from"] || %{}
    reply_to = get_in(msg, ["reply_to_message", "message_id"])

    {slash_command, content} = extract_command(text)

    {:ok,
     %Message{
       id: generate_id(),
       channel: :telegram,
       channel_message_id: to_string(msg["message_id"] || ""),
       space_id: to_string(chat["id"] || ""),
       thread_id: if(reply_to, do: to_string(reply_to)),
       user_id: to_string(from["id"] || ""),
       user_display_name: build_display_name(from),
       user_email: nil,
       content: String.trim(content),
       argument_text: if(slash_command, do: String.trim(content)),
       slash_command: slash_command,
       attachments: [],
       metadata: %{
         "update_id" => msg["message_id"],
         "chat_type" => chat["type"],
         "chat_title" => chat["title"]
       },
       timestamp: parse_timestamp(msg["date"])
     }}
  end

  # Ignore all non-text-message updates
  def normalize(_update), do: {:error, :ignored}

  @impl true
  @doc """
  Send a text reply to a Telegram chat.

  Maps the `thread_name` option (from Dispatcher) to `reply_to_message_id`
  for Telegram's reply threading.
  """
  @spec send_reply(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_reply(chat_id, text, opts \\ []) do
    client_opts =
      case Keyword.get(opts, :thread_name) do
        nil -> []
        reply_to -> [reply_to_message_id: reply_to]
      end

    case Client.send_message(chat_id, text, client_opts) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @doc "Returns the list of capabilities supported by Telegram."
  def capabilities, do: [:typing, :markdown_formatting]

  @impl true
  @doc "Send a typing indicator to the given chat."
  def send_typing(chat_id) do
    case Client.send_chat_action(chat_id, "typing") do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # --- Helpers ---

  # Extract bot command from text. Returns {command, arguments} or {nil, text}.
  # Telegram commands start with `/` and may include the bot username:
  #   "/search quarterly report" → {"/search", "quarterly report"}
  #   "/help@mybot" → {"/help", ""}
  #   "hello" → {nil, "hello"}
  defp extract_command(text) do
    case Regex.run(~r/^(\/\w+)(?:@\w+)?\s*(.*)$/s, text) do
      [_full, command, args] -> {command, args}
      nil -> {nil, text}
    end
  end

  defp build_display_name(from) do
    first = from["first_name"] || ""
    last = from["last_name"] || ""

    case String.trim("#{first} #{last}") do
      "" -> nil
      name -> name
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(unix_ts) when is_integer(unix_ts) do
    case DateTime.from_unix(unix_ts) do
      {:ok, dt} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp generate_id do
    "tg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
