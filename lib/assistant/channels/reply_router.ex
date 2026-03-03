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
    Includes retry with exponential backoff for transient failures.

  - `send_to/3,4` — Proactive messaging: looks up the user's identity for
    a specific channel in user_identities and sends via the adapter.

  - `broadcast/2,3` — Sends a message to ALL channels where a user has
    registered identities. Returns results per channel.

  ## Future: Connection Pooling

  For high-volume deployments, each adapter's HTTP client should be backed by
  a connection pool (e.g., NimblePool or Finch pools). The pool would be
  configured per adapter since each platform API has different concurrency
  characteristics:

    * Google Chat — moderate concurrency, rate-limited per space
    * Telegram — high concurrency, per-bot rate limits (30 msg/sec)
    * Slack — moderate, tier-based rate limits per method
    * Discord — low-moderate, per-route rate limits with bucket headers

  Implementation path: create a `ConnectionPool` module that wraps NimblePool
  with per-adapter pool sizing. Configure via `config :assistant, :adapter_pools`.
  Each adapter's `send_reply/3` would check out a connection from its pool
  rather than opening a new HTTP connection per request.
  """

  import Ecto.Query

  alias Assistant.Channels.Registry
  alias Assistant.Repo
  alias Assistant.Schemas.UserIdentity

  require Logger

  # Retry configuration for transient failures in reply/2.
  # Backoff intervals in ms: 100ms → 500ms → 2000ms
  @retry_backoffs [100, 500, 2000]

  # Transient error reasons that justify a retry.
  @transient_errors [:timeout, :econnrefused, :econnreset, :closed, :nxdomain]

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

    with_retry(adapter, @retry_backoffs, fn ->
      adapter.send_reply(origin.space_id, text, reply_opts)
    end)
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

    delay_ms = Application.get_env(:assistant, :broadcast_delay_ms, 100)

    identities
    |> Enum.with_index()
    |> Enum.flat_map(fn {identity, index} ->
      # Delay between sends (not before the first one)
      if index > 0 and delay_ms > 0, do: Process.sleep(delay_ms)

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

  # Retry helper with exponential backoff for transient errors.
  # Permanent errors (e.g., :unauthorized, :not_found) are returned immediately.
  defp with_retry(adapter, backoffs, fun)

  defp with_retry(_adapter, [], fun) do
    fun.()
  end

  defp with_retry(adapter, [delay | rest], fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} when reason in @transient_errors ->
        Logger.warning("Transient error from adapter, retrying",
          adapter: inspect(adapter),
          error: inspect(reason),
          remaining_retries: length(rest),
          backoff_ms: delay
        )

        Process.sleep(delay)
        with_retry(adapter, rest, fun)

      other ->
        other
    end
  end

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
