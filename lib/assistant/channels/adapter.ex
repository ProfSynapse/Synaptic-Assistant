# lib/assistant/channels/adapter.ex — Channel adapter behaviour.
#
# Defines the contract that all channel adapters (Google Chat, Telegram, etc.)
# must implement. Each adapter normalizes raw platform events into a
# Channels.Message struct and provides a method for sending replies back.
#
# Related files:
#   - lib/assistant/channels/message.ex (the normalized message struct)
#   - lib/assistant/channels/google_chat.ex (Google Chat implementation — Wave 2)

defmodule Assistant.Channels.Adapter do
  @moduledoc """
  Behaviour for channel adapters.

  Each adapter translates between a specific messaging platform's wire format
  and the internal `Assistant.Channels.Message` struct used by the orchestrator.

  ## Callbacks

    * `normalize/1` — Convert a raw event payload into a `Message.t()`
    * `send_reply/3` — Send a text reply to a specific space/channel
    * `channel_name/0` — Return the atom identifier for this channel

  ## Example

      defmodule Assistant.Channels.GoogleChat do
        @behaviour Assistant.Channels.Adapter

        @impl true
        def channel_name, do: :google_chat

        @impl true
        def normalize(raw_event), do: ...

        @impl true
        def send_reply(space_id, text, opts \\\\ []), do: ...
      end
  """

  @type normalized_message :: Assistant.Channels.Message.t()

  @doc "Convert a raw platform event into a normalized Message struct."
  @callback normalize(raw_event :: map()) :: {:ok, normalized_message()} | {:error, term()}

  @doc "Send a text reply to the given space/channel."
  @callback send_reply(space_id :: String.t(), text :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Return the atom identifier for this channel (e.g., :google_chat, :telegram)."
  @callback channel_name() :: atom()
end
