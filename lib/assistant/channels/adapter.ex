# lib/assistant/channels/adapter.ex — Channel adapter behaviour.
#
# Defines the contract that all channel adapters (Google Chat, Telegram, etc.)
# must implement. Each adapter normalizes raw platform events into a
# Channels.Message struct and provides a method for sending replies back.
#
# Optional callbacks allow adapters to declare channel-specific capabilities
# (typing indicators, rich messages, webhook management) without forcing all
# adapters to implement features they don't support.
#
# Related files:
#   - lib/assistant/channels/message.ex (the normalized message struct)
#   - lib/assistant/channels/google_chat.ex (Google Chat implementation)
#   - lib/assistant/channels/dispatcher.ex (shared dispatch logic)
#   - lib/assistant/channels/registry.ex (channel atom → module mapping)

defmodule Assistant.Channels.Adapter do
  @moduledoc """
  Behaviour for channel adapters.

  Each adapter translates between a specific messaging platform's wire format
  and the internal `Assistant.Channels.Message` struct used by the orchestrator.

  ## Required Callbacks

    * `channel_name/0` — Return the atom identifier for this channel
    * `normalize/1` — Convert a raw event payload into a `Message.t()`
    * `send_reply/3` — Send a text reply to a specific space/channel

  ## Optional Callbacks

    * `capabilities/0` — List supported features (e.g., `:typing`, `:rich_cards`)
    * `send_typing/1` — Send a typing indicator to a space/channel
    * `send_rich_message/3` — Send a rich message (card, block kit, etc.)
    * `setup_webhook/1` — Register or update a webhook for this channel

  ## Example

      defmodule Assistant.Channels.GoogleChat do
        @behaviour Assistant.Channels.Adapter

        @impl true
        def channel_name, do: :google_chat

        @impl true
        def normalize(raw_event), do: ...

        @impl true
        def send_reply(space_id, text, opts \\\\ []), do: ...

        # Optional: declare supported capabilities
        @impl true
        def capabilities, do: [:rich_cards]
      end
  """

  @type normalized_message :: Assistant.Channels.Message.t()

  # --- Required Callbacks ---

  @doc "Return the atom identifier for this channel (e.g., :google_chat, :telegram)."
  @callback channel_name() :: atom()

  @doc "Convert a raw platform event into a normalized Message struct."
  @callback normalize(raw_event :: map()) :: {:ok, normalized_message()} | {:error, term()}

  @doc "Send a text reply to the given space/channel."
  @callback send_reply(space_id :: String.t(), text :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  # --- Optional Callbacks ---

  @doc """
  Return a list of capability atoms supported by this channel.

  Common capabilities: `:typing`, `:rich_cards`, `:threads`, `:reactions`,
  `:inline_keyboards`, `:markdown_formatting`.
  """
  @callback capabilities() :: [atom()]

  @doc "Send a typing indicator to the given space/channel."
  @callback send_typing(space_id :: String.t()) :: :ok | {:error, term()}

  @doc "Send a rich message (card, block kit, etc.) to the given space/channel."
  @callback send_rich_message(space_id :: String.t(), card :: map(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Register or update a webhook for this channel. Returns webhook metadata on success."
  @callback setup_webhook(config :: map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks capabilities: 0,
                      send_typing: 1,
                      send_rich_message: 3,
                      setup_webhook: 1
end
