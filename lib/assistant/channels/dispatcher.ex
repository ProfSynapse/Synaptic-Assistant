# lib/assistant/channels/dispatcher.ex — Shared channel dispatch logic.
#
# Extracts the normalize → resolve → engine → reply flow for all channel
# webhook controllers. Controllers remain thin (auth + delegation).
#
# The dispatch flow:
#   1. Normalize the raw event via the adapter's normalize/1 callback
#   2. Spawn an async task under the shared TaskSupervisor
#   3. In the task: resolve platform identity → ensure engine → send message → reply
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour that adapters implement)
#   - lib/assistant/channels/registry.ex (channel atom → module mapping)
#   - lib/assistant/channels/user_resolver.ex (platform identity → DB user)
#   - lib/assistant/channels/reply_router.ex (outbound message routing)
#   - lib/assistant/orchestrator/engine.ex (conversation processing)

defmodule Assistant.Channels.Dispatcher do
  @moduledoc """
  Shared dispatch logic for all channel adapters.

  Accepts a normalized `%Message{}` struct (already produced by the channel's
  adapter) and handles the async processing pipeline: resolve the platform
  identity to a DB user, start or look up the conversation engine, send the
  message through the orchestrator, and deliver the response back via the
  ReplyRouter.

  ## Usage

  Channel controllers call `dispatch/2` after normalizing the event:

      case ChatAdapter.normalize(params) do
        {:ok, message} ->
          Dispatcher.dispatch(ChatAdapter, message)
          json(conn, %{"text" => "Processing..."})
        {:error, :ignored} ->
          send_resp(conn, 200, "")
      end
  """

  alias Assistant.Channels.{ReplyRouter, UserResolver}
  alias Assistant.Orchestrator.Engine

  require Logger

  @error_message "I encountered an error processing your message. Please try again."
  @engine_error_message "I encountered an error starting the conversation engine. Please try again."
  @resolve_error_message "I couldn't identify your account. Please contact an administrator."
  @not_allowed_message "Your account is not authorized to use this assistant. Please contact an administrator."

  @doc """
  Dispatch a normalized message for async processing.

  Spawns a task that resolves the platform identity, sends the message
  through the orchestrator engine, and replies via the ReplyRouter.
  Returns immediately with `{:ok, :dispatched}`.

  ## Parameters

    * `adapter` - The adapter module (must implement `Channels.Adapter`)
    * `message` - A normalized `%Channels.Message{}` struct
    * `opts` - Optional keyword list (reserved for future use)

  ## Returns

    * `{:ok, :dispatched}` — The task was spawned successfully
    * `{:error, term()}` — The task could not be started
  """
  @spec dispatch(module(), Assistant.Channels.Message.t(), keyword()) ::
          {:ok, :dispatched} | {:error, term()}
  def dispatch(adapter, message, opts \\ []) do
    case Task.Supervisor.start_child(
           Assistant.Skills.TaskSupervisor,
           fn -> process_and_reply(adapter, message, opts) end
         ) do
      {:ok, _pid} -> {:ok, :dispatched}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Async Processing (runs inside the spawned task) ---

  defp process_and_reply(adapter, message, _opts) do
    # F8: Set correlation ID for all log lines in this message's processing
    Logger.metadata(correlation_id: message.id)

    # M7+F1: Telemetry — dispatch start
    start_time = System.monotonic_time()
    metadata = %{channel: message.channel, message_id: message.id}

    :telemetry.execute(
      [:assistant, :channels, :dispatch, :start],
      %{system_time: System.system_time()},
      metadata
    )

    # Step 1: Resolve platform identity to DB user + perpetual conversation
    case UserResolver.resolve(message.channel, message.user_id, %{
           display_name: message.user_display_name,
           space_id: message.space_id
         }) do
      {:ok, %{user_id: user_id, conversation_id: conversation_id}} ->
        resolve_time = System.monotonic_time()

        :telemetry.execute(
          [:assistant, :channels, :dispatch, :resolve],
          %{duration: resolve_time - start_time},
          Map.put(metadata, :user_id, user_id)
        )

        # Build origin for reply routing (hot path — no DB lookup needed)
        origin = build_origin(adapter, message)

        case ensure_engine_started(user_id, conversation_id, message) do
          :ok ->
            handle_engine_response(origin, user_id, message, start_time, metadata)

          {:error, reason} ->
            Logger.error(
              "Failed to start engine for user #{user_id}: #{inspect(reason)}",
              channel: message.channel,
              user_id: user_id
            )

            emit_error_telemetry(start_time, metadata, :engine_start_failed)
            ReplyRouter.reply(origin, @engine_error_message)
        end

      {:error, :not_allowed} ->
        Logger.warning("User not on allowlist, message rejected",
          channel: message.channel,
          external_id: message.user_id
        )

        emit_error_telemetry(start_time, metadata, :not_allowed)
        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @not_allowed_message, reply_opts)

      {:error, :invalid_platform_id} ->
        Logger.warning("Rejected message with invalid platform ID",
          channel: message.channel,
          external_id: message.user_id
        )

        emit_error_telemetry(start_time, metadata, :invalid_platform_id)
        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @resolve_error_message, reply_opts)

      {:error, reason} ->
        Logger.error("User resolution failed: #{inspect(reason)}",
          channel: message.channel,
          external_id: message.user_id
        )

        emit_error_telemetry(start_time, metadata, reason)
        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @error_message, reply_opts)
    end
  rescue
    error ->
      Logger.error("Unhandled error in async channel processing: #{inspect(error)}",
        channel: message.channel,
        stacktrace: inspect(__STACKTRACE__)
      )

      try do
        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @error_message, reply_opts)
      rescue
        _ -> :ok
      end
  end

  defp handle_engine_response(origin, user_id, message, start_time, metadata) do
    engine_start = System.monotonic_time()

    # Engine is now registered by user_id UUID
    case Engine.send_message(user_id, message.content) do
      {:ok, response_text} ->
        engine_time = System.monotonic_time()

        :telemetry.execute(
          [:assistant, :channels, :dispatch, :engine],
          %{duration: engine_time - engine_start},
          Map.put(metadata, :user_id, user_id)
        )

        case ReplyRouter.reply(origin, response_text) do
          :ok ->
            reply_time = System.monotonic_time()

            :telemetry.execute(
              [:assistant, :channels, :dispatch, :reply],
              %{duration: reply_time - start_time},
              Map.put(metadata, :user_id, user_id)
            )

            Logger.debug("Channel reply sent",
              user_id: user_id,
              channel: origin.channel,
              space_id: origin.space_id
            )

          {:error, reason} ->
            Logger.error("Failed to send channel reply: #{inspect(reason)}",
              user_id: user_id,
              channel: origin.channel,
              space_id: origin.space_id
            )

            emit_error_telemetry(start_time, Map.put(metadata, :user_id, user_id), :reply_failed)
        end

      {:error, reason} ->
        Logger.error("Orchestrator processing failed: #{inspect(reason)}",
          user_id: user_id,
          channel: origin.channel
        )

        emit_error_telemetry(start_time, Map.put(metadata, :user_id, user_id), :engine_failed)
        ReplyRouter.reply(origin, @error_message)
    end
  end

  # Emits the error telemetry event with duration and reason.
  defp emit_error_telemetry(start_time, metadata, reason) do
    :telemetry.execute(
      [:assistant, :channels, :dispatch, :error],
      %{duration: System.monotonic_time() - start_time},
      Map.put(metadata, :reason, reason)
    )
  end

  # --- Helpers ---

  # Build an origin map carrying everything ReplyRouter.reply/3 needs for the
  # hot-path reply (no DB lookup required).
  defp build_origin(adapter, message) do
    %{
      adapter: adapter,
      channel: message.channel,
      space_id: message.space_id,
      thread_id: message.thread_id
    }
  end

  # Start the orchestrator engine for this user if not already running.
  # Engine is registered by user_id UUID.
  defp ensure_engine_started(user_id, conversation_id, message) do
    case Engine.get_state(user_id) do
      {:ok, _state} ->
        :ok

      {:error, :not_found} ->
        start_engine(user_id, conversation_id, message)
    end
  end

  defp start_engine(user_id, conversation_id, message) do
    opts = [
      user_id: user_id,
      conversation_id: conversation_id,
      channel: to_string(message.channel),
      mode: :multi_agent
    ]

    child_spec = %{
      id: user_id,
      start: {Engine, :start_link, [user_id, opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(
           Assistant.Orchestrator.ConversationSupervisor,
           child_spec
         ) do
      {:ok, _pid} ->
        Logger.info("Started conversation engine",
          user_id: user_id,
          conversation_id: conversation_id,
          channel: message.channel
        )

        :ok

      {:error, {:already_started, _pid}} ->
        # Race condition — another request started it between our check and start
        :ok

      {:error, reason} ->
        Logger.error("Failed to start conversation engine: #{inspect(reason)}",
          user_id: user_id
        )

        {:error, reason}
    end
  end

  # Build reply options from the message (used in error fallback paths
  # where we call adapter.send_reply directly instead of ReplyRouter).
  defp build_reply_opts(message) do
    if message.thread_id do
      [thread_name: message.thread_id]
    else
      []
    end
  end
end
