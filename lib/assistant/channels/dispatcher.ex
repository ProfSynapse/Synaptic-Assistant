# lib/assistant/channels/dispatcher.ex — Shared channel dispatch logic.
#
# Extracts the normalize → engine → reply flow that was previously embedded in
# GoogleChatController. All channel webhook controllers delegate to this module
# for async message processing, keeping controllers thin (auth + delegation).
#
# The dispatch flow:
#   1. Normalize the raw event via the adapter's normalize/1 callback
#   2. Spawn an async task under the shared TaskSupervisor
#   3. In the task: derive a conversation ID, ensure the engine is running,
#      send the message, and reply via the adapter's send_reply/3
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour that adapters implement)
#   - lib/assistant/channels/registry.ex (channel atom → module mapping)
#   - lib/assistant/orchestrator/engine.ex (conversation processing)
#   - lib/assistant_web/controllers/google_chat_controller.ex (primary consumer)

defmodule Assistant.Channels.Dispatcher do
  @moduledoc """
  Shared dispatch logic for all channel adapters.

  Accepts a normalized `%Message{}` struct (already produced by the channel's
  adapter) and handles the async processing pipeline: start or look up the
  conversation engine, send the message through the orchestrator, and deliver
  the response back via the adapter's `send_reply/3` callback.

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

  alias Assistant.Orchestrator.Engine

  require Logger

  @error_message "I encountered an error processing your message. Please try again."
  @engine_error_message "I encountered an error starting the conversation engine. Please try again."

  @doc """
  Dispatch a normalized message for async processing.

  Spawns a task that sends the message through the orchestrator engine and
  replies via the adapter. Returns immediately with `{:ok, :dispatched}`.

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
    conversation_id = derive_conversation_id(message)

    case ensure_engine_started(conversation_id, message) do
      :ok ->
        handle_engine_response(adapter, message, conversation_id)

      {:error, reason} ->
        Logger.error("Failed to start engine for conversation",
          conversation_id: conversation_id,
          channel: message.channel,
          reason: inspect(reason)
        )

        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @engine_error_message, reply_opts)
    end
  rescue
    error ->
      Logger.error("Unhandled error in async channel processing",
        channel: message.channel,
        error: inspect(error),
        stacktrace: inspect(__STACKTRACE__)
      )

      # Best-effort error reply so the user's message doesn't silently disappear.
      # Wrapped in try/rescue to avoid masking the original error.
      try do
        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @error_message, reply_opts)
      rescue
        _ -> :ok
      end
  end

  defp handle_engine_response(adapter, message, conversation_id) do
    case Engine.send_message(conversation_id, message.content) do
      {:ok, response_text} ->
        reply_opts = build_reply_opts(message)

        case adapter.send_reply(message.space_id, response_text, reply_opts) do
          :ok ->
            Logger.debug("Channel reply sent",
              conversation_id: conversation_id,
              channel: message.channel,
              space_id: message.space_id
            )

          {:error, reason} ->
            Logger.error("Failed to send channel reply",
              conversation_id: conversation_id,
              channel: message.channel,
              space_id: message.space_id,
              reason: inspect(reason)
            )
        end

      {:error, reason} ->
        Logger.error("Orchestrator processing failed",
          conversation_id: conversation_id,
          channel: message.channel,
          reason: inspect(reason)
        )

        reply_opts = build_reply_opts(message)
        adapter.send_reply(message.space_id, @error_message, reply_opts)
    end
  end

  # --- Helpers ---

  @doc false
  # Derive a stable conversation ID from the channel, space, and thread.
  # Format: "{channel}:{space_id}" or "{channel}:{space_id}:{thread_id}"
  def derive_conversation_id(message) do
    base = "#{message.channel}:#{message.space_id}"

    if message.thread_id do
      "#{base}:#{message.thread_id}"
    else
      base
    end
  end

  # Start the orchestrator engine for this conversation if not already running.
  defp ensure_engine_started(conversation_id, message) do
    case Engine.get_state(conversation_id) do
      {:ok, _state} ->
        :ok

      {:error, :not_found} ->
        start_engine(conversation_id, message)
    end
  end

  defp start_engine(conversation_id, message) do
    opts = [
      user_id: message.user_id,
      channel: to_string(message.channel),
      mode: :multi_agent
    ]

    child_spec = %{
      id: conversation_id,
      start: {Engine, :start_link, [conversation_id, opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(
           Assistant.Orchestrator.ConversationSupervisor,
           child_spec
         ) do
      {:ok, _pid} ->
        Logger.info("Started conversation engine",
          conversation_id: conversation_id,
          channel: message.channel,
          user_id: message.user_id
        )

        :ok

      {:error, {:already_started, _pid}} ->
        # Race condition — another request started it between our check and start
        :ok

      {:error, reason} ->
        Logger.error("Failed to start conversation engine",
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Build reply options from the message. Adapters may use thread_id for
  # threaded replies (e.g., Google Chat thread_name).
  defp build_reply_opts(message) do
    if message.thread_id do
      [thread_name: message.thread_id]
    else
      []
    end
  end
end
