# lib/assistant/channels/message.ex — Normalized channel message struct.
#
# A channel-agnostic representation of an incoming user message. Channel
# adapters (Google Chat, Telegram, etc.) normalize their raw events into
# this struct before handing off to the orchestrator engine.
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour that produces this struct)
#   - lib/assistant/orchestrator/engine.ex (consumes this struct)

defmodule Assistant.Channels.Message do
  @moduledoc """
  Normalized message struct for cross-channel communication.

  All channel adapters convert their platform-specific payloads into this
  common struct so the orchestrator can process messages uniformly regardless
  of the originating channel.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          channel: atom(),
          channel_message_id: String.t(),
          space_id: String.t(),
          thread_id: String.t() | nil,
          user_id: String.t(),
          user_display_name: String.t() | nil,
          user_email: String.t() | nil,
          content: String.t(),
          argument_text: String.t() | nil,
          slash_command: String.t() | nil,
          attachments: [map()],
          metadata: map(),
          timestamp: DateTime.t() | nil
        }

  @enforce_keys [:id, :channel, :channel_message_id, :space_id, :user_id, :content]
  defstruct [
    :id,
    :channel,
    :channel_message_id,
    :space_id,
    :thread_id,
    :user_id,
    :user_display_name,
    :user_email,
    :content,
    :argument_text,
    :slash_command,
    :timestamp,
    attachments: [],
    metadata: %{}
  ]
end
