# lib/assistant/channels/dispatcher.ex — Shared channel dispatch logic.
#
# Extracts the normalize → resolve → engine → reply flow for all channel
# webhook controllers. Controllers remain thin (auth + delegation).
#
# Two dispatch modes:
#   - dispatch/2,3: Async — spawns a task, returns immediately. Controller
#     sends a placeholder response and the reply goes via ReplyRouter.
#   - dispatch_sync/2,3: Synchronous — runs the pipeline in the caller's
#     process, returns {:ok, response_text} or {:error, reason}. Used by
#     channels (e.g., Google Chat) that return the response in the HTTP body.
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
  adapter) and handles the processing pipeline: resolve the platform identity
  to a DB user, start or look up the conversation engine, send the message
  through the orchestrator, and deliver the response.

  ## Dispatch Modes

  ### Async (default)

  `dispatch/2` spawns a background task. The controller returns a placeholder
  response immediately and the actual reply is sent via the ReplyRouter.

      Dispatcher.dispatch(ChatAdapter, message)
      json(conn, %{"text" => "Processing..."})

  ### Synchronous

  `dispatch_sync/2` runs the full pipeline in the caller's process and
  returns the response text. Used by channels that need to return the
  response in the HTTP body (e.g., Google Chat v2 Workspace Add-ons).

      case Dispatcher.dispatch_sync(message) do
        {:ok, response_text} -> json(conn, wrap_response(response_text))
        {:error, error_text} -> json(conn, wrap_response(error_text))
      end
  """

  alias Assistant.Channels.{MessageFormatter, ReplyRouter, SpaceContextFanoutWorker, UserResolver}
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

  @doc """
  Dispatch a normalized message synchronously.

  Runs the full resolve → engine → response pipeline in the caller's process
  and returns the response text. Does NOT send via ReplyRouter — the caller
  is responsible for delivering the response (e.g., in the HTTP body).

  ## Parameters

    * `message` - A normalized `%Channels.Message{}` struct
    * `opts` - Optional keyword list (reserved for future use)

  ## Returns

    * `{:ok, response_text}` — Engine produced a response
    * `{:error, error_message}` — An error occurred; the error_message is
      a user-facing string suitable for returning in the response body
  """
  @spec dispatch_sync(Assistant.Channels.Message.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def dispatch_sync(message, opts \\ []) do
    process_and_return(message, opts)
  end

  # --- Synchronous Processing (runs in the caller's process) ---

  defp process_and_return(message, _opts) do
    Logger.metadata(correlation_id: message.id)

    start_time = System.monotonic_time()
    metadata = %{channel: message.channel, message_id: message.id}

    :telemetry.execute(
      [:assistant, :channels, :dispatch, :start],
      %{system_time: System.system_time()},
      metadata
    )

    case UserResolver.resolve(message.channel, message.user_id, %{
           display_name: message.user_display_name,
           space_id: message.space_id,
           user_email: message.user_email
         }) do
      {:ok, %{user_id: user_id, conversation_id: conversation_id}} ->
        :telemetry.execute(
          [:assistant, :channels, :dispatch, :resolve],
          %{duration: System.monotonic_time() - start_time},
          Map.put(metadata, :user_id, user_id)
        )

        case ensure_engine_started(user_id, conversation_id, message) do
          :ok ->
            sync_engine_response(user_id, message, start_time, metadata)

          {:error, reason} ->
            Logger.error("Failed to start engine for user #{user_id}: #{inspect(reason)}",
              channel: message.channel,
              user_id: user_id
            )

            emit_error_telemetry(start_time, metadata, :engine_start_failed)
            {:error, @engine_error_message}
        end

      {:error, :not_allowed} ->
        Logger.warning("User not on allowlist, message rejected",
          channel: message.channel,
          external_id: message.user_id
        )

        emit_error_telemetry(start_time, metadata, :not_allowed)
        {:error, @not_allowed_message}

      {:error, :invalid_platform_id} ->
        Logger.warning("Rejected message with invalid platform ID",
          channel: message.channel,
          external_id: message.user_id
        )

        emit_error_telemetry(start_time, metadata, :invalid_platform_id)
        {:error, @resolve_error_message}

      {:error, reason} ->
        Logger.error("User resolution failed: #{inspect(reason)}",
          channel: message.channel,
          external_id: message.user_id
        )

        emit_error_telemetry(start_time, metadata, reason)
        {:error, @error_message}
    end
  rescue
    error ->
      Logger.error("Unhandled error in sync channel processing: #{inspect(error)}",
        channel: message.channel,
        stacktrace: inspect(__STACKTRACE__)
      )

      {:error, @error_message}
  end

  defp sync_engine_response(user_id, message, start_time, metadata) do
    engine_start = System.monotonic_time()
    engine_message_metadata = build_engine_message_metadata(message)

    case Engine.send_message(user_id, message.content, metadata: engine_message_metadata) do
      {:ok, response_text} ->
        engine_time = System.monotonic_time()

        :telemetry.execute(
          [:assistant, :channels, :dispatch, :engine],
          %{duration: engine_time - engine_start},
          Map.put(metadata, :user_id, user_id)
        )

        :telemetry.execute(
          [:assistant, :channels, :dispatch, :reply],
          %{duration: engine_time - start_time},
          Map.put(metadata, :user_id, user_id)
        )

        # Post-reply hook: enqueue space context fan-out for shared GChat spaces
        maybe_enqueue_space_context(message, user_id, message.content, response_text)

        {:ok, MessageFormatter.format(response_text, message.channel)}

      {:error, reason} ->
        Logger.error("Orchestrator processing failed: #{inspect(reason)}",
          user_id: user_id,
          channel: message.channel
        )

        emit_error_telemetry(start_time, Map.put(metadata, :user_id, user_id), :engine_failed)
        {:error, @error_message}
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
           space_id: message.space_id,
           user_email: message.user_email
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
    engine_message_metadata = build_engine_message_metadata(message)

    # Engine is now registered by user_id UUID
    case Engine.send_message(user_id, message.content, metadata: engine_message_metadata) do
      {:ok, response_text} ->
        engine_time = System.monotonic_time()

        :telemetry.execute(
          [:assistant, :channels, :dispatch, :engine],
          %{duration: engine_time - engine_start},
          Map.put(metadata, :user_id, user_id)
        )

        formatted_text = MessageFormatter.format(response_text, message.channel)

        case ReplyRouter.reply(origin, formatted_text) do
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

            # Post-reply hook: enqueue space context fan-out for shared GChat spaces
            maybe_enqueue_space_context(message, user_id, message.content, response_text)

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

  defp build_engine_message_metadata(message) do
    source =
      %{
        "kind" => "channel",
        "channel" => to_string(message.channel),
        "message_id" => present_or_nil(message.channel_message_id),
        "space_id" => present_or_nil(message.space_id),
        "thread_id" => present_or_nil(message.thread_id),
        "external_user_id" => present_or_nil(message.user_id),
        "user_display_name" => present_or_nil(message.user_display_name),
        "user_email" => present_or_nil(message.user_email)
      }
      |> compact_map()

    channel_metadata =
      case message.metadata do
        %{} = metadata when map_size(metadata) > 0 -> metadata
        _ -> nil
      end

    %{
      "source" => source,
      "channel_metadata" => channel_metadata
    }
    |> compact_map()
  end

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc ->
        acc

      {_key, ""}, acc ->
        acc

      {_key, %{} = value}, acc when map_size(value) == 0 ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp present_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_or_nil(value), do: value

  # Enqueue space context fan-out for Google Chat space messages.
  # Skips DMs and non-GChat channels.
  defp maybe_enqueue_space_context(message, user_id, question, response) do
    space_type = get_in(message.metadata, ["space_type"])

    cond do
      message.channel != :google_chat ->
        :ok

      dm_space?(space_type) ->
        :ok

      is_nil(message.space_id) or message.space_id == "" ->
        :ok

      true ->
        args = %{
          "space_id" => message.space_id,
          "sender_user_id" => user_id,
          "sender_email" => message.user_email,
          "sender_display_name" => message.user_display_name,
          "question" => question,
          "response" => response,
          "space_type" => space_type
        }

        case SpaceContextFanoutWorker.new(args) |> Oban.insert() do
          {:ok, _job} ->
            Logger.debug("Enqueued space context fan-out",
              space_id: message.space_id,
              sender: user_id
            )

          {:error, reason} ->
            Logger.warning("Failed to enqueue space context fan-out: #{inspect(reason)}",
              space_id: message.space_id
            )
        end
    end
  end

  defp dm_space?(nil), do: false
  defp dm_space?("DM"), do: true
  defp dm_space?("DIRECT_MESSAGE"), do: true
  defp dm_space?(_), do: false
end
