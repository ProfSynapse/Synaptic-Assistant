# lib/assistant/channels/discord.ex — Discord channel adapter.
#
# Converts raw Discord Interaction payloads into the normalized
# Channels.Message struct and delegates replies to the Discord Bot API client.
#
# Discord bots using the HTTP interactions endpoint receive slash commands
# (APPLICATION_COMMAND type 2) and component interactions, but NOT regular
# messages. This adapter normalizes slash command interactions into the
# standard Message struct.
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour this module implements)
#   - lib/assistant/channels/message.ex (normalized message struct)
#   - lib/assistant/integrations/discord/client.ex (Bot API HTTP client)
#   - lib/assistant_web/controllers/discord_controller.ex (consumer)

defmodule Assistant.Channels.Discord do
  @moduledoc """
  Discord channel adapter.

  Implements `Assistant.Channels.Adapter` to normalize incoming Discord
  Interaction payloads into `%Assistant.Channels.Message{}` structs and
  send replies via the Discord Bot API.

  ## Supported Interaction Types

    * Type 2 (`APPLICATION_COMMAND`) — Slash commands (e.g., `/ask how's the weather`)

  ## Ignored Interaction Types

    * Type 1 (`PING`) — Handled directly by the controller (PONG response)
    * Type 3 (`MESSAGE_COMPONENT`) — Button/select interactions (not yet supported)
    * Type 4 (`APPLICATION_COMMAND_AUTOCOMPLETE`) — Autocomplete (not yet supported)
    * Messages from bot users (`author.bot == true`)
  """

  @behaviour Assistant.Channels.Adapter

  alias Assistant.Channels.Message
  alias Assistant.Integrations.Discord.Client

  @impl true
  def channel_name, do: :discord

  @impl true
  @doc """
  Convert a Discord Interaction payload into a normalized Message struct.

  Expects the full interaction object from the Discord webhook.

  Returns `{:ok, message}` for APPLICATION_COMMAND interactions.
  Returns `{:error, :ignored}` for PING, bot messages, and unsupported types.
  """
  @spec normalize(map()) :: {:ok, Message.t()} | {:error, :ignored}

  # APPLICATION_COMMAND (type 2) — slash commands
  def normalize(%{"type" => 2} = interaction) do
    member = interaction["member"] || %{}
    user = member["user"] || interaction["user"] || %{}

    # Filter bot users
    if user["bot"] == true do
      {:error, :ignored}
    else
      guild_id = interaction["guild_id"] || ""
      channel_id = interaction["channel_id"] || ""
      user_id = user["id"] || ""

      # Extract command name and options text
      data = interaction["data"] || %{}
      command_name = data["name"] || ""
      options_text = extract_options_text(data["options"])

      {:ok,
       %Message{
         id: generate_id(),
         channel: :discord,
         channel_message_id: interaction["id"] || "",
         space_id: scope_id(guild_id, channel_id),
         thread_id: nil,
         user_id: scope_id(guild_id, user_id),
         user_display_name: build_display_name(member, user),
         user_email: nil,
         content: String.trim(options_text),
         argument_text: if(options_text != "", do: String.trim(options_text)),
         slash_command: "/#{command_name}",
         attachments: [],
         metadata: %{
           "interaction_id" => interaction["id"],
           "interaction_type" => 2,
           "guild_id" => guild_id,
           "channel_id" => channel_id,
           "command_name" => command_name
         },
         timestamp: parse_timestamp(interaction["id"])
       }}
    end
  end

  # All other interaction types (PING is handled by controller, rest ignored)
  def normalize(_interaction), do: {:error, :ignored}

  @impl true
  @doc """
  Send a text reply to a Discord channel.

  Uses the Discord Bot API to send a message. Maps `thread_name` option
  to channel_id override for threaded replies.
  """
  @spec send_reply(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_reply(channel_id, text, opts \\ []) do
    # Extract the raw channel_id from the scoped ID if needed
    raw_channel_id = extract_channel_id(channel_id)

    client_opts =
      case Keyword.get(opts, :thread_name) do
        nil -> []
        thread_id -> [thread_id: thread_id]
      end

    case Client.send_message(raw_channel_id, text, client_opts) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @doc "Returns the list of capabilities supported by Discord."
  def capabilities, do: [:typing, :threads, :rich_cards, :markdown_formatting]

  @impl true
  @doc "Send a typing indicator to the given channel."
  def send_typing(channel_id) do
    raw_channel_id = extract_channel_id(channel_id)

    case Client.trigger_typing(raw_channel_id) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # --- Helpers ---

  # Extract options text from slash command options.
  # Discord sends options as a list of {name, type, value} maps.
  # We concatenate all string/integer option values into a single text.
  defp extract_options_text(nil), do: ""
  defp extract_options_text([]), do: ""

  defp extract_options_text(options) when is_list(options) do
    options
    |> Enum.map(fn opt -> to_string(opt["value"] || "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # Build a globally-unique scoped ID: "discord:{guild_id}:{local_id}"
  # nil or "" guild_id indicates a DM context — use "dm" as scope prefix.
  defp scope_id(nil, local_id), do: "discord:dm:#{local_id}"
  defp scope_id("", local_id), do: "discord:dm:#{local_id}"
  defp scope_id(guild_id, local_id), do: "discord:#{guild_id}:#{local_id}"

  # Extract raw channel_id from scoped "discord:guild:channel" format.
  defp extract_channel_id(scoped_id) do
    case String.split(scoped_id, ":") do
      ["discord", _guild, channel_id] -> channel_id
      _ -> scoped_id
    end
  end

  # Build display name from member nick or user global_name/username.
  defp build_display_name(member, user) do
    member["nick"] || user["global_name"] || user["username"]
  end

  # Discord snowflake IDs encode a timestamp.
  # Snowflake = (timestamp_ms - discord_epoch) << 22 | ...
  # Discord epoch: 1420070400000 (2015-01-01T00:00:00.000Z)
  @discord_epoch 1_420_070_400_000

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(snowflake_str) when is_binary(snowflake_str) do
    case Integer.parse(snowflake_str) do
      {snowflake, ""} ->
        timestamp_ms = Bitwise.bsr(snowflake, 22) + @discord_epoch

        case DateTime.from_unix(timestamp_ms, :millisecond) do
          {:ok, dt} -> dt
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp generate_id do
    "discord_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
