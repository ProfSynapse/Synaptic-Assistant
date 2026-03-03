# lib/assistant/channels/reply_router.ex — Routes outbound messages to channels.
#
# Provides three routing strategies:
#   - reply/2,3: hot-path reply to the originating channel (no DB lookup)
#   - send_to/3,4: proactive message to a specific channel (DB lookup)
#   - broadcast/2,3: send to all channels for a user (DB lookup)
#
# Related files:
#   - lib/assistant/channels/adapter.ex (adapter behaviour)
#   - lib/assistant/channels/registry.ex (channel atom → module mapping)
#   - lib/assistant/channels/dispatcher.ex (primary consumer)
#   - lib/assistant/schemas/user_identity.ex (identity table for lookups)

defmodule Assistant.Channels.ReplyRouter do
  @moduledoc """
  Routes outbound messages to the correct channel adapter(s).

  ## Routing Strategies

  - `reply/2,3` — Hot path: uses origin metadata from the inbound message,
    no DB lookup needed. Used by the Dispatcher for turn-based responses.

  - `send_to/3,4` — Proactive messaging: looks up the user's identity for
    a specific channel in user_identities and sends via the adapter.

  - `broadcast/2,3` — Sends a message to ALL channels where a user has
    registered identities. Returns results per channel.
  """

  import Ecto.Query

  alias Assistant.Channels.Registry
  alias Assistant.Repo
  alias Assistant.Schemas.UserIdentity

  require Logger

  @doc """
  Replies to the originating channel using the origin metadata.

  This is the hot path — no DB lookup needed. The origin map carries
  the adapter module, space_id, and thread_id from the inbound message.

  ## Parameters

    * `origin` - Map with `:adapter`, `:channel`, `:space_id`, `:thread_id`
    * `text` - Response text to send
    * `opts` - Additional options passed to the adapter (default: [])

  ## Returns

    * `:ok` on success
    * `{:error, term()}` on failure
  """
  @spec reply(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def reply(origin, text, opts \\ []) do
    adapter = origin.adapter
    reply_opts = build_reply_opts(origin, opts)

    adapter.send_reply(origin.space_id, text, reply_opts)
  end

  @doc """
  Sends a proactive message to a user on a specific channel.

  Looks up the user's identity for the given channel in user_identities
  and sends via the corresponding adapter.

  ## Parameters

    * `user_id` - DB user UUID
    * `channel` - Channel atom (e.g., `:telegram`)
    * `text` - Message text to send
    * `opts` - Additional options passed to the adapter (default: [])

  ## Returns

    * `:ok` on success
    * `{:error, :no_identity}` if user has no identity on this channel
    * `{:error, :unknown_channel}` if channel has no registered adapter
    * `{:error, term()}` on adapter failure
  """
  @spec send_to(binary(), atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_to(user_id, channel, text, opts \\ []) do
    with {:ok, adapter} <- Registry.adapter_for(channel),
         {:ok, identity} <- find_user_identity(user_id, channel) do
      space_id = identity.space_id || identity.external_id
      adapter.send_reply(space_id, text, opts)
    end
  end

  @doc """
  Broadcasts a message to all channels where a user has identities.

  Sends to each registered channel sequentially and returns results per channel.
  Identities on unknown/unregistered channels are skipped with a warning.

  ## Parameters

    * `user_id` - DB user UUID
    * `text` - Message text to send
    * `opts` - Additional options passed to adapters (default: [])

  ## Returns

    * List of `{channel_atom, :ok | {:error, term()}}` tuples
  """
  @spec broadcast(binary(), String.t(), keyword()) :: [{atom(), :ok | {:error, term()}}]
  def broadcast(user_id, text, opts \\ []) do
    # Build a reverse map from channel string → {atom, module} using the
    # Registry as the source of truth. This avoids String.to_existing_atom
    # which can raise ArgumentError if the channel string in the DB doesn't
    # correspond to a loaded atom.
    adapter_by_string =
      Registry.all_channels()
      |> Map.new(fn channel_atom ->
        {:ok, adapter} = Registry.adapter_for(channel_atom)
        {to_string(channel_atom), {channel_atom, adapter}}
      end)

    identities = list_user_identities(user_id)

    identities
    |> Enum.flat_map(fn identity ->
      case Map.get(adapter_by_string, identity.channel) do
        {channel_atom, adapter} ->
          space_id = identity.space_id || identity.external_id
          result = adapter.send_reply(space_id, text, opts)
          [{channel_atom, result}]

        nil ->
          Logger.warning("Broadcast skipping unknown channel",
            channel: identity.channel,
            user_id: user_id
          )

          []
      end
    end)
  end

  # --- Private ---

  defp build_reply_opts(origin, opts) do
    base =
      if origin[:thread_id] do
        [thread_name: origin.thread_id]
      else
        []
      end

    Keyword.merge(base, opts)
  end

  defp find_user_identity(user_id, channel) do
    query =
      from ui in UserIdentity,
        where: ui.user_id == ^user_id and ui.channel == ^to_string(channel),
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :no_identity}
      identity -> {:ok, identity}
    end
  end

  defp list_user_identities(user_id) do
    from(ui in UserIdentity,
      where: ui.user_id == ^user_id,
      order_by: [asc: ui.inserted_at]
    )
    |> Repo.all()
  end
end
